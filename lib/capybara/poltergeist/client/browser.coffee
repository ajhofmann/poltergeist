web_page = require("./web_page.js")
puppeteer = require('puppeteer')

class Poltergeist.Browser
  constructor: (width, height) ->
    @width      = width || 1024
    @height     = height || 768
    @pages      = []
    @js_errors  = true
    @_debug     = false
    @_counter   = 0

    @processed_modal_messages = []
    @confirm_processes = []
    @prompt_responses = []

   launch: ->
     @browser = await puppeteer.launch(headless: false)
     @resetPage()

  resetPage: ->
    [@_counter, @pages] = [0, []]

    if @page?
      unless @page.closed
        # @page.clearLocalStorage() if @page.currentUrl() != 'about:blank'
        @page.close()
      # phantom.clearCookies()

    @page = @currentPage = await @_open_new_window()
    return true

  getPageByHandle: (handle) ->
    @pages.filter((p) -> !p.closed && p.handle == handle)[0]

  runCommand: (command) ->
    @current_command = command
    @currentPage.state = 'default'
    this[command.name].apply(this, command.args)

  debug: (message) ->
    console.log "poltergeist [#{new Date().getTime()}] #{message}" if @_debug

  setModalMessage: (msg) ->
    @processed_modal_messages.push(msg)
    return

  add_extension: (extension) ->
    @current_command.sendResponse(
      @currentPage.injectExtension(extension).then ->
        'success'
      .catch (err)->
        throw "Unable to load extension: #{extension}"
    )

  node: (page_id, id) ->
    if @currentPage.id == page_id
      @currentPage.get(id)
    else
      throw new Poltergeist.ObsoleteNode

  visit: (url, max_wait=30) ->
    @currentPage.state = 'loading'
    #reset modal processing state when changing page
    @processed_modal_messages = []
    @confirm_processes = []
    @prompt_responses = []

    prevUrl = await @currentPage.currentUrl()
    goto_options = { timeout: max_wait*1000 }
    if /#/.test(url) && prevUrl.split('#')[0] == url.split('#')[0]
      # Hash change occurred, so there will be no 'load' event
      goto_options['waitUntil'] = 'networkidle'
      goto_options['networkIdleTimeout'] = 100

    command = @current_command
    loading_page = @currentPage
    @currentPage.goto(url, goto_options).then (response)->
      loading_page.state = 'default'
      command.sendResponse(status: response?.status || 'success')
    .catch (err)->
      resources = loading_page.openResourceRequests()
      msg = if resources.length
        "Timed out with the following resources still waiting #{resources.join(',')}"
      else
        "Request blocked or timed out with no open resource requests"
      command.sendError(new Poltergeist.StatusFailError(url,msg))
    return

  current_url: ->
    @current_command.sendResponse @currentPage.currentUrl()

  status_code: ->
    @current_command.sendResponse @currentPage.statusCode

  body: ->
    @current_command.sendResponse @currentPage.content()

  source: ->
    @current_command.sendResponse @currentPage.source

  title: ->
    @current_command.sendResponse @currentPage.title()

  find: (method, selector) ->
    @current_command.sendResponse(
      @currentPage.find(method,selector).then (ids)=>
        { page_id: @currentPage.id, ids }
    )
    return

  find_within: (page_id, id, method, selector) ->
    @current_command.sendResponse @node(page_id, id).find(method, selector)

  all_text: (page_id, id) ->
    @current_command.sendResponse @node(page_id, id).allText()

  visible_text: (page_id, id) ->
    @current_command.sendResponse @node(page_id, id).visibleText()

  delete_text: (page_id, id) ->
    @current_command.sendResponse @node(page_id, id).deleteText()

  property: (page_id, id, name) ->
    @current_command.sendResponse @node(page_id, id).getProperty(name)

  attribute: (page_id, id, name) ->
    @current_command.sendResponse @node(page_id, id).getAttribute(name)

  attributes: (page_id, id, name) ->
    @current_command.sendResponse @node(page_id, id).getAttributes()

  parents: (page_id, id) ->
    @current_command.sendResponse @node(page_id, id).parentIds()

  value: (page_id, id) ->
    @current_command.sendResponse @node(page_id, id).value()

  set: (page_id, id, value) ->
    @current_command.sendResponse(@node(page_id, id).set(value))

  # PhantomJS only allows us to reference the element by CSS selector, not XPath,
  # so we have to add an attribute to the element to identify it, then remove it
  # afterwards.
  select_file: (page_id, id, files) ->
    node = @node(page_id, id)
    await @current_command.sendResponse @currentPage.beforeAction(node.id)
    await @currentPage.uploadFile('[_poltergeist_selected]', files...)
    await @currentPage.afterAction(node.id)

  select: (page_id, id, value) ->
    @current_command.sendResponse this.node(page_id, id).select(value)

  tag_name: (page_id, id) ->
    @current_command.sendResponse this.node(page_id, id).tagName()

  visible: (page_id, id) ->
    @current_command.sendResponse this.node(page_id, id).isVisible()

  disabled: (page_id, id) ->
    @current_command.sendResponse this.node(page_id, id).isDisabled()

  path: (page_id, id) ->
    @current_command.sendResponse this.node(page_id, id).path()

  evaluate: (script, args...) ->
    for arg in args when @_isElementArgument(arg)
      throw new Poltergeist.ObsoleteNode if arg["ELEMENT"]["page_id"] != @currentPage.id
    @current_command.sendResponse @currentPage.evaluate("function() { return #{script} }", args...)

  execute: (script, args...) ->
    for arg in args when @_isElementArgument(arg)
      throw new Poltergeist.ObsoleteNode if arg["ELEMENT"]["page_id"] != @currentPage.id
    @current_command.sendResponse @currentPage.execute("function() { #{script} }", args...)

  frameUrl: (frame_name) ->
    @currentPage.frameUrl(frame_name)

  pushFrame: (command, node, timeout) ->
    frame = @node(node...)
    attrs = await frame.getAttributes('name', 'id')
    name = attrs['name'] || attrs['id']
    name = await frame.setAttribute('name', "_random_name_#{new Date().getTime()}") unless name
    frame_url = await @frameUrl(name)
    if frame_url in @currentPage.blockedUrls()
      console.log "frame blocked"
      command.sendResponse(true)
    else
      cur_frame = await @currentPage.pushFrame(name)
      if cur_frame
        await cur_frame.waitFor('html')
        command.sendResponse(true)
      else
        if new Date().getTime() < timeout
          setTimeout((=> @pushFrame(command, node, timeout)), 50)
        else
          command.sendError(new Poltergeist.FrameNotFound(name))
    return true

  push_frame: (node, timeout = (new Date().getTime()) + 2000) ->
    @pushFrame(@current_command, node, timeout)

  pop_frame: (pop_all = false)->
    @current_command.sendResponse(@currentPage.popFrame(pop_all))

  window_handles: ->
    handles = @pages.filter((p) -> !p.closed).map((p) -> p.handle)
    @current_command.sendResponse(handles)

  window_handle: (name = null) ->
    handle = if name
      page = @pages.filter((p) -> !p.closed && p.windowName() == name)[0]
      if popFramepage then page.handle else null
    else
      @currentPage.handle

    @current_command.sendResponse(handle)

  switch_to_window: (handle) ->
    command = @current_command
    new_page = @getPageByHandle(handle)
    if new_page
      if new_page != @currentPage
        new_page.waitState 'default', =>
          @currentPage = new_page
          command.sendResponse(true)
      else
        command.sendResponse(true)
    else
      throw new Poltergeist.NoSuchWindowError

  open_new_window: ->
    # this.execute 'window.open()'
    # @current_command.sendResponse(true)
    page = await @_open_new_window()
    page.handle = "#{@_counter++}"
    page.setBlacklist @page.urlBlacklist
    page.setWhitelist @page.urlWhitelist
    await page.setViewportSize(@page.viewportSize())
    @current_command.sendResponse(true)

  _open_new_window: ->
    native_page = await @browser.newPage()
    page = new Poltergeist.WebPage(native_page)
    await page.initialize()
    page.handle = "#{@_counter++}"
    @pages.push(page)

    native_page.on 'dialog', (dialog)=>
      @setModalMessage dialog.message()
      switch dialog.type
        when 'alert'
          dialog.dismiss()
        when 'confirm', 'beforeunload'
          process = @confirm_processes.pop()
          process = true if process == undefined
          if process
            dialog.accept()
          else
            dialog.dismiss()
        when 'prompt'
          response = if @prompt_responses.length
            response = @prompt_responses.pop()
          else
            false
          response = dialog.defaultValue() if response == false
          if response?
            dialog.accept(response)
          else
            dialog.dismiss()
        else
          throw "Unknown dialog type #{dialog.type}"

    # page.onPageCreated = (newPage) =>
    #   page = new Poltergeist.WebPage(newPage)
    #   page.handle = "#{@_counter++}"
    #   page.setViewportSize(@page.viewportSize())
    #   @pages.push(page)

    @processed_modal_messages = []
    @confirm_processes = []
    @prompt_responses = []
    await page.setViewportSize(width: parseInt(@width,10), height: parseInt( @height,10))
    return page

  close_window: (handle) ->
    page = @getPageByHandle(handle)
    if page
      page.close()
      @current_command.sendResponse(true)
    else
      @current_command.sendResponse(false)

  mouse_event: (page_id, id, name) ->
    # Get the node before changing state, in case there is an exception
    node = @node(page_id, id)
    # If the event triggers onNavigationRequested, we will transition to the 'loading'
    # state and wait for onLoadFinished before sending a response.
    @currentPage.state = 'mouse_event'

    node.mouseEvent(name).then (last_mouse_event)=>
      event_page = @currentPage
      command = @current_command

      return new Promise((resolve)->
             setTimeout(->
               if event_page.state == 'mouse_event'
                 event_page.state = 'default'
                 command.sendResponse(position: last_mouse_event)
               else
                 event_page.waitState 'default', ->
                   command.sendResponse(position: last_mouse_event)
                   resolve()
               resolve()
             , 100)
            )
      # setTimeout ->
      #   # If the state is still the same then navigation event won't happen
      #   if event_page.state == 'mouse_event'
      #     console.log "going back to default"
      #     event_page.state = 'default'
      #     console.log "sending:"
      #     console.dir last_mouse_event
      #     command.sendResponse(position: last_mouse_event)
      #   else
      #     console.log "going to wait for default"
      #     event_page.waitState 'default', ->
      #       console.log "page made it to default"
      #       command.sendResponse(position: last_mouse_event)
      #   return true
      # , 1000
      # return true
    .catch (err) =>
      console.log "in catch"
      @current_command.sendError err


  click: (page_id, id) ->
    this.mouse_event(page_id, id, 'click').catch (err)->
      console.log "error in click"

  right_click: (page_id, id) ->
    this.mouse_event page_id, id, 'rightclick'
  double_click: (page_id, id) ->
    this.mouse_event page_id, id, 'dblclick'

  hover: (page_id, id) ->
    node = @node(page_id, id)
    # Puppeteer requires locating the element by css to call hover, so we need to adjust element
    @current_command.sendResponse(
      @currentPage.beforeAction(node.id).then =>
        @currentPage.native().hover('[_poltergeist_selected]').then =>
          @currentPage.afterAction(node.id)
    )

  click_coordinates: (x, y) ->
    @currentPage.native().mouse.click(x,y).then =>
      @current_command.sendResponse(click: { x: x, y: y })

  drag: (page_id, id, other_id) ->
    @current_command.sendResponse(
      this.node(page_id, id).dragTo this.node(page_id, other_id)
    )

  drag_by: (page_id, id, x, y) ->
    @current_command.sendResponse(
      this.node(page_id, id).dragBy(x, y)
    )

  trigger: (page_id, id, event) ->
    this.node(page_id, id).trigger(event)
    @current_command.sendResponse(event)

  equals: (page_id, id, other_id) ->
    @current_command.sendResponse this.node(page_id, id).isEqual(this.node(page_id, other_id))

  reset: ->
    @current_command.sendResponse(@resetPage())

  scroll_to: (left, top) ->
    @current_command.sendResponse @currentPage.setScrollPosition(left: left, top: top)

  send_keys: (page_id, id, keys) ->
    target = @node(page_id, id)
    # Programmatically generated focus doesn't work for `sendKeys`.
    # That's why we need something more realistic like user behavior.
    cs = await target.containsSelection()
    await target.mouseEvent('click') if !cs
    @current_command.sendResponse( @_send_keys_with_modifiers(keys) )

  _send_keys_with_modifiers: (keys) ->
    for sequence in keys
      if sequence.key?
        key = {key: sequence.key}
      else if sequence.keys?
        key = sequence.keys
      else
        key = sequence

      if sequence.modifier?
        modifier_keys = @currentPage.keyModifierKeys(sequence.modifier)
        await @currentPage.native().keyboard.down(modifier_key) for modifier_key in modifier_keys
        await @_send_keys_with_modifiers([].concat(key))
        await @currentPage.native().keyboard.up(modifier_key) for modifier_key in modifier_keys
      else if sequence.key?
        await @currentPage.native().press(sequence.key)
      else
        await @currentPage.native().type(key)
    return true

  render_base64: (format='png', { full = false, selector = null } = {})->
    options = {
      fullPage: full
      type: format
    }
    p = if options['fullPage']
      Promise.resolve(null)
    else
      @get_clip_rect(full, selector)
    p.then (rect)=>
      options['clip'] = rect if rect?
      @currentPage.native().screenshot(options).then (buffer)=>
        @current_command.sendResponse(buffer.toString('base64'))

  render: (path, { full = false, selector = null, format = null, quality = null } = {} ) ->
    options = {
      path: path
      fullPage: full
    }
    options['type']=format if format?
    options['quality']=quality if quality?
    p = if options['fullPage']
      Promise.resolve(null)
    else
      @get_clip_rect(full, selector)
    p.then (rect)=>
      options['clip'] = rect if rect?
      @currentPage.native().screenshot(options).then =>
        @current_command.sendResponse(true)

  get_clip_rect: (full, selector) ->
    @currentPage.dimensions().then (dimensions)=>
      [document, viewport] = [dimensions.document, dimensions.viewport]
      if full
        x: 0, y: 0, width: document.width, height: document.height
      else
        if selector?
          @currentPage.elementBounds(selector)
        else
          x: 0, y: 0, width: viewport.width, height: viewport.height

  set_paper_size: (size) ->
    @currentPage.setPaperSize(size)
    @current_command.sendResponse(true)

  set_zoom_factor: (zoom_factor) ->
    @currentPage.setZoomFactor(zoom_factor)
    @current_command.sendResponse(true)

  resize: (width, height) ->
    @current_command.sendResponse(
      @currentPage.setViewportSize(width: parseInt(width, 10), height: parseInt(height,10)).then ->
        true
    )

  network_traffic: (type) ->
    @current_command.sendResponse(@currentPage.networkTraffic(type))

  clear_network_traffic: ->
    @currentPage.clearNetworkTraffic()
    @current_command.sendResponse(true)

  set_proxy: (ip, port, type, user, password) ->
    throw "implement set_proxy"
    phantom.setProxy(ip, port, type, user, password)
    @current_command.sendResponse(true)

  get_headers: ->
    @current_command.sendResponse(@currentPage.getCustomHeaders())

  set_headers: (headers) ->
    @currentPage.setCustomHeaders(headers).then =>
      @current_command.sendResponse(true)

  add_headers: (headers) ->
    allHeaders = @currentPage.getCustomHeaders()
    for name, value of headers
      allHeaders[name] = value
    this.set_headers(allHeaders)

  add_header: (header, { permanent = true }) ->
    unless permanent == true
      @currentPage.addTempHeader(header)
      @currentPage.addTempHeaderToRemoveOnRedirect(header) if permanent == "no_redirect"
    this.add_headers(header)

  response_headers: ->
    @current_command.sendResponse(@currentPage.responseHeaders())

  cookies: ->
    @current_command.sendResponse(@currentPage.cookies())

  # We're using phantom.addCookie so that cookies can be set
  # before the first page load has taken place.
  set_cookie: (cookie) ->
    throw "implement set_cookie"
    phantom.addCookie(cookie)
    @current_command.sendResponse(true)

  remove_cookie: (name) ->
    @currentPage.deleteCookie(name)
    @current_command.sendResponse(true)

  clear_cookies: () ->
    phantom.clearCookies()
    @current_command.sendResponse(true)

  cookies_enabled: (flag) ->
    throw "implement cookies_enabled"
    phantom.cookiesEnabled = flag
    @current_command.sendResponse(true)

  set_http_auth: (user, password) ->
    @currentPage.setHttpAuth(user, password)
    @current_command.sendResponse(true)

  set_js_errors: (value) ->
    @js_errors = value
    @current_command.sendResponse(true)

  set_debug: (value) ->
    @_debug = value
    @current_command.sendResponse(true)

  exit: ->
    @browser.close()

  noop: ->
    # NOOOOOOP!

  # This command is purely for testing error handling
  browser_error: ->
    throw new Error('zomg')

  go_back: ->
    @currentPage.state = 'wait_for_loading'
    @currentPage.goBack().then => @_waitForHistoryChange()

  go_forward: ->
    @currentPage.state = 'wait_for_loading'
    @currentPage.goForward().then => @_waitForHistoryChange()

  refresh: ->
    @currentPage.state = 'wait_for_loading'
    @currentPage.reload().then => @_waitForHistoryChange()

  set_url_whitelist: (wildcards...)->
    @currentPage.setWhitelist(@_wildcardToRegexp(wc) for wc in wildcards)
    @current_command.sendResponse(true)

  set_url_blacklist: (wildcards...)->
    @currentPage.setBlacklist(@_wildcardToRegexp(wc) for wc in wildcards)
    @current_command.sendResponse(true)

  set_confirm_process: (process) ->
    @confirm_processes.push process
    @current_command.sendResponse(true)

  set_prompt_response: (response) ->
    @prompt_responses.push response
    @current_command.sendResponse(true)

  modal_message: ->
    @current_command.sendResponse(@processed_modal_messages.shift())

  clear_memory_cache: ->
    @currentPage.clearMemoryCache()
    @current_command.sendResponse(true)

  _waitForHistoryChange: ->
    command = @current_command
    @currentPage.waitState ['loading','default'], (cur_state) ->
      if cur_state == 'loading'
        # loading has started, wait for completion
        @waitState 'default', ->
          command.sendResponse(true)
      else
        # page has loaded
        command.sendResponse(true)
    , 0.5, ->
      # if haven't moved to loading/default in time assume history API state change
      @state = 'default'
      command.sendResponse(true)

  _wildcardToRegexp: (wildcard)->
    wildcard = wildcard.replace(/[\-\[\]\/\{\}\(\)\+\.\\\^\$\|]/g, "\\$&")
    wildcard = wildcard.replace(/\*/g, ".*")
    wildcard = wildcard.replace(/\?/g, ".")
    new RegExp(wildcard, "i")

  _isElementArgument: (arg)->
    typeof(arg) == "object" and typeof(arg['ELEMENT']) == "object"
