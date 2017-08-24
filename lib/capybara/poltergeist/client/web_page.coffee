node = require("./node.js")
fs = require('fs')

tab_id = 0
class Poltergeist.WebPage
  @CALLBACKS = ['onLoadFinished', 'onInitialized', 'onLoadStarted',
                'onResourceReceived',
                'onNavigationRequested', 'onUrlChanged', 'onPageCreated',
                'onClosing', 'request', 'requestfinished', 'requestfailed', 'response',
                'error', 'pageerror', 'console', 'framenavigated', 'frameattached', 'load']

  @PAGE_DELEGATES = ['goto', 'render', 'close', 'goBack', 'goForward', 'reload']

  @COMMANDS  = ['find', 'nodeCall', 'documentSize', 'beforeAction', 'afterAction', 'clearLocalStorage']

  @EXTENSIONS = []

  for command in @COMMANDS
    do (command) =>
      WebPage.prototype[command] = (args...)->
        this.runCommand(command, args)

  for delegate in @PAGE_DELEGATES
    do (delegate) =>
      WebPage.prototype[delegate] = ->
        @_native[delegate]?.apply(@_native, arguments)

  constructor: (@_native) ->
    @id              = ++tab_id
    @source          = null
    @closed          = false
    @state           = 'default'
    @frames          = []
    @urlWhitelist    = []
    @urlBlacklist    = []
    @errors          = []
    @_networkTraffic = {}
    @_customHeaders  = {}
    @_tempHeaders    = {}
    @_blockedUrls    = []
    @_requestedResources = {}
    @_responseHeaders = []
    @_tempHeadersToRemoveOnRedirect = {}

    for callback in WebPage.CALLBACKS
      @bindCallback(callback)

  initialize: ->
    Promise.all(
      for filePath in ["./lib/capybara/poltergeist/client/compiled/agent.js", WebPage.EXTENSIONS...]
        @_add_injection(filePath).then (contents)=>
          @currentFrame().evaluate(contents)
    ).then =>
      return true

  # onInitializedNative: ->
  #   @id += 1
  #   @source = null
  #   @removeTempHeaders()
  #   @removeTempHeadersForRedirect()
  #   @setScrollPosition(left: 0, top: 0)

  onClosingNative: ->
    @handle = null
    @closed = true

  on_console: (message, args...) ->
    if message == '__DOMContentLoaded'
      # @source = @_native.content
      # false
    else
      console.log(message)

  on_pageerror: (message)->
    # Puppeteer doesn't seem to provide the stack
    #   stackString = message
    #
    #   stack.forEach (frame) ->
    #     stackString += "\n"
    #     stackString += "    at #{frame.file}:#{frame.line}"
    #     stackString += " in #{frame.function}" if frame.function && frame.function != ''
    #
    @errors.push(message: message.toString(), stack: message.toString())
    true

  on_error: (error)->
    @errors.push(message: error.message.toString(), stack: error.stack.toString())
    true

  on_framenavigated: (frame)->
    if frame._id == @currentFrame()._id
      @state = 'loading'
      @requestId = @lastRequestId
      @_requestedResources = {}
    true

  on_load: ->
    @state = 'default'
    @id = ++tab_id
    # @source or= @_native.content

  # onLoadFinishedNative: (@status) ->
  #   @state = 'default'
  #   @source or= @_native.content

  on_request: (request) ->
    @_networkTraffic[request._requestId] = {
      request:       request,
      responseParts: []
      error: null
    }

    # Intecepting causes the `Referer` header to be lost, therefore
    # we only intercept when black/whitelist are set so we can
    # maintain the headers for now
    if @_intercepting()
      if @_blockRequest(request.url)
        @_networkTraffic[request._requestId].blocked = true
        @_blockedUrls.push request.url unless request.url in @_blockedUrls
        request.abort()
      else
        @lastRequestId = request._requestId

        # @normalizeURL(request.url).then (url)=>
        #   if (url == @redirectURL)
        #     @removeTempHeadersForRedirect()
        #     @redirectURL = null
        #     @requestId   = request._requestId

        @_requestedResources[request._requestId] = request.url
        request.continue()
    else
      @lastRequestId = request._requestId
      @_requestedResources[request._requestId] = request.url
    return true

  on_response: (response) ->
    @_networkTraffic[response.request._requestId]?.responseParts.push(response)

    return true

  on_requestfinished: (request) ->
    @_networkTraffic[request._requestId]?.responseParts.push(request.response())

    delete @_requestedResources[request.requestId]

    if @requestId == request._requestId
      if request.response().redirectURL
        @removeTempHeadersForRedirect()
        # @normalizeURL(response.redirectURL).then (url)=>
        #   @redirectURL = url
      else
        @statusCode = request.response().status
        @_responseHeaders = request.response().headers

  on_requestfailed: (request) ->
    @_networkTraffic[request._requestId]?.error = request
    delete @_requestedResources[request._requestId]
    return true

  injectExtension: (filePath) ->
    WebPage.EXTENSIONS.push filePath
    @_add_injection(filePath)

  native: ->
    if @closed
      throw new Poltergeist.NoSuchWindowError
    else
      @_native

  currentUrl: ->
    # Puppeteer url doesn't reflect
    # @native().url()
    @currentFrame().evaluate ->
      window.location.href

  currentFrame: ->
    @frames[@frames.length-1] || @native().mainFrame()

  uploadFile: (selector, file_paths...)->
    eh = await @currentFrame().$(selector)
    await eh.uploadFile(file_paths...)

  windowName: ->
    @native().windowName

  keyModifierKeys: (names) ->
    for name in names.split(',') when name isnt 'keypad'
      name = name.charAt(0).toUpperCase() + name.substring(1)
      if name == "Ctrl"
        "Control"
      else
        name

  _waitState_until: (states, callback, timeout, timeout_callback) ->
    if (@state in states)
      callback.call(this, @state)
    else
      if new Date().getTime() > timeout
        timeout_callback.call(this)
      else
        setTimeout (=> @_waitState_until(states, callback, timeout, timeout_callback)), 100

  waitState: (states, callback, max_wait=0, timeout_callback) ->
    # callback and timeout_callback will be called with this == the current page
    states = [].concat(states)
    if @state in states
      callback.call(this, @state)
    else
      if max_wait != 0
        timeout = new Date().getTime() + (max_wait*1000)
        setTimeout (=> @_waitState_until(states, callback, timeout, timeout_callback)), 100
      else
        setTimeout (=> @waitState(states, callback)), 100

  setHttpAuth: (user, password) ->
    @native().settings.userName = user
    @native().settings.password = password
    return true

  networkTraffic: (type) ->
    console.log "traffic is"
    console.dir @_networkTraffic
    requests = switch type
      when 'all'
        request for own id, request of @_networkTraffic
      when 'blocked'
        request for own id, request of @_networkTraffic when request.blocked
      else
        request for own id, request of @_networkTraffic when not request.blocked
    for request in requests
      JSON.stringify(request, ['_requestId', 'url', 'method', 'postData', 'headers', 'blocked'])

  clearNetworkTraffic: ->
    @_networkTraffic = {}
    return true

  blockedUrls: ->
    @_blockedUrls

  clearBlockedUrls: ->
    @_blockedUrls = []
    return true

  openResourceRequests: ->
    url for own id, url of @_requestedResources

  content: ->
    @native().content()

  title: ->
    @native().title()

  frameUrl: (frameNameOrId) ->
    query = (frameNameOrId) ->
      document.querySelector("iframe[name='#{frameNameOrId}'], iframe[id='#{frameNameOrId}']")?.src
    @evaluate(query, frameNameOrId)

  clearErrors: ->
    @errors = []
    return true

  responseHeaders: ->
    headers = {}
    @_responseHeaders.forEach (value, key) ->
      headers[key] = value
    headers

  cookies: ->
    @currentFrame().cookies

  deleteCookie: (name) ->
    @currentFrame().deleteCookie(name)

  viewportSize: ->
    @native().viewport()

  setViewportSize: (size) ->
    @native().setViewport size

  setZoomFactor: (zoom_factor) ->
    @native().zoomFactor = zoom_factor

  setPaperSize: (size) ->
    @native().paperSize = size

  scrollPosition: ->
    throw "not implemented"
    @native().scrollPosition

  setScrollPosition: (pos) ->
    @currentFrame().evaluate (x,y)->
      window.scrollTo(x,y)
    , pos.left, pos.top

  # clipRect: ->
  #   this.native().clipRect
  #
  # setClipRect: (rect) ->
  #   this.native().clipRect = rect

  elementBounds: (selector) ->
    @currentFrame().evaluate((selector) ->
      rect = document.querySelector(selector).getBoundingClientRect()
      return x: rect.x, y: rect.y, width: rect.width, height: rect.height, top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right
    , selector)

  setUserAgent: (userAgent) ->
    @native().setUserAgent userAgent

  getCustomHeaders: ->
    @_customHeaders

  setCustomHeaders: (headers) ->
    @_customHeaders = headers
    (if @_customHeaders['User-Agent']
      @setUserAgent(@_customHeaders['User-Agent'])
    else
      Promise.resolve()).then =>
        map = new Map()
        map.set(name, value) for name, value of headers
        @native().setExtraHTTPHeaders(map)

  addTempHeader: (header) ->
    for name, value of header
      @_tempHeaders[name] = value
    @_tempHeaders

  addTempHeaderToRemoveOnRedirect: (header) ->
    for name, value of header
      @_tempHeadersToRemoveOnRedirect[name] = value
    @_tempHeadersToRemoveOnRedirect

  removeTempHeadersForRedirect: ->
    allHeaders = @getCustomHeaders()
    for name, value of @_tempHeadersToRemoveOnRedirect
      delete allHeaders[name]
    @setCustomHeaders(allHeaders)

  removeTempHeaders: ->
    allHeaders = @getCustomHeaders()
    for name, value of @_tempHeaders
      delete allHeaders[name]
    @setCustomHeaders(allHeaders)

  pushFrame: (name) ->
    new_frame = (frame for frame in @currentFrame().childFrames() when frame.name() == name)[0]
    if new_frame
      @frames.push new_frame
      Promise.resolve(new_frame)
    else
      promises = for frame in @currentFrame().childFrames()
        frame.evaluate ->
          # window.frameElement.getAttribute("Name")
          window.frameElement
      Promise.all(promises).then (results)->
        Promise.resolve()

  popFrame: (pop_all = false)->
    if pop_all
      @frames = []
    else
      @frames.pop()
    true

  dimensions: ->
    @documentSize().then (d_size)=>
    # scroll   = this.scrollPosition()
      scroll = { top: 0, left: 0}
      viewport = this.viewportSize()

      top:    scroll.top,  bottom: scroll.top  + viewport.height,
      left:   scroll.left, right:  scroll.left + viewport.width,
      viewport: viewport
      document: d_size

  get: (id) ->
    new Poltergeist.Node(this, id)

  # Before each mouse event we make sure that the mouse is moved to where the
  # event will take place. This deals with e.g. :hover changes.
  mouseEvent: (name, x, y, button = 'left') ->
    switch name
      when 'click'
        @native().mouse.click(x,y)
      when 'dblclick'
        @native().mouse.click(x,y, clickCount: 2)
      when 'mousedown'
        # console.log "moving to #{x}, #{y} then downing mouse"
        @native().mouse.move(x,y).then => @native().mouse.down
      when 'mouseup'
        # console.log "moving to #{x}, #{y} then uping mouse"
        @native().mouse.move(x,y).then => @native().mouse.up
      else
        throw "Unknown mouse event #{name}"

  evaluate: (fn, args...) ->
    fn_args = (JSON.stringify(arg) for arg in [@id, args...])
    wrapped_fn = "(function() {
      var page_id = arguments[0];
      var args = [];

      for(var i=1; i < arguments.length; i++){
        var arg = arguments[i];
        if ((typeof(arg) == 'object') && (typeof(arg['ELEMENT']) == 'object')){
          args.push(window.__poltergeist.get(arg['ELEMENT']['id']).element);
        } else {
          args.push(arg)
        }
      }
      var _result = #{this.stringifyCall(fn, "args")};
      return window.__poltergeist.wrapResults(_result, page_id); })(#{fn_args.join(',')})"
    @currentFrame().evaluate(wrapped_fn).catch (err)->
      throw new Poltergeist.JavascriptError([message: err.toString(), stack: err.toString()])

  execute: (fn, args...) ->
    fn_args = (JSON.stringify(arg) for arg in args)

    wrapped_fn = "(function() {
      var args = [];
      for(var i=0; i < arguments.length; i++){
        var arg = arguments[i];
        if ((typeof(arg) == 'object') && (typeof(arg['ELEMENT']) == 'object')){
          args.push(window.__poltergeist.get(arg['ELEMENT']['id']).element);
        } else {
          args.push(arg)
        }
      }
      #{this.stringifyCall(fn, "args")} })(#{fn_args.join(',')})"
    @currentFrame().evaluate(wrapped_fn).catch (err)->
      throw new Poltergeist.JavascriptError([message: err.toString(), stack: err.toString()])

  stringifyCall: (fn, args_name = "arguments") ->
    "(#{fn.toString()}).apply(this, #{args_name})"

  bindCallback: (name) ->
    @native().on name, (args...)=>
      return @["on_#{name}"].apply(@, args) if @["on_#{name}"]? # For internal callbacks
      return false
    return true

  # Any error raised here or inside the evaluate will get reported to
  # phantom.onError. If result is null, that means there was an error
  # inside the agent.
  runCommand: (name, args) ->
    this.evaluate(
      (cmd_name, cmd_args) ->
        __poltergeist.externalCall(cmd_name, cmd_args)
      ,name, args
    ).then (result)->
      if result?.error?
        switch result.error.message
          when 'PoltergeistAgent.ObsoleteNode'
            throw new Poltergeist.ObsoleteNode
          when 'PoltergeistAgent.InvalidSelector'
            [method, selector] = args
            throw new Poltergeist.InvalidSelector(method, selector)
          else
            throw new Poltergeist.BrowserError(result.error.message, result.error.stack)
      else
        result?.value

  # canGoBack: ->
  #   this.native().canGoBack
  #
  # canGoForward: ->
  #   this.native().canGoForward

  normalizeURL: (url)->
    console.log "implement normalizeURL"
    parser = document.createElement('a')
    parser.href = url
    parser.href

  clearMemoryCache: ->
    clearMemoryCache = @native().clearMemoryCache
    if typeof clearMemoryCache == "function"
      clearMemoryCache()
    else
      throw new Poltergeist.UnsupportedFeature("clearMemoryCache is not supported in Puppeteer")

  setBlacklist: (bl)->
    @urlBlacklist = bl
    await @native().setRequestInterceptionEnabled(@_intercepting())

  setWhitelist: (bl)->
    @urlWhitelist = bl
    await @native().setRequestInterceptionEnabled(@_intercepting())

  _intercepting: ->
    @urlWhitelist.length || @urlBlacklist.length

  _blockRequest: (url) ->
    useWhitelist = @urlWhitelist.length > 0

    whitelisted = @urlWhitelist.some (whitelisted_regex) ->
      whitelisted_regex.test url

    blacklisted = @urlBlacklist.some (blacklisted_regex) ->
      blacklisted_regex.test url

    (useWhitelist && !whitelisted) || blacklisted

  _add_injection: (filePath)->
    new Promise (resolve, reject)->
      try
        fs.readFile filePath, 'utf8', (err, data) ->
          if err
            reject(err)
          else
            resolve(data)
      catch err
        reject(err)
    .then (contents)=>
      @native().evaluateOnNewDocument(contents)
      contents
