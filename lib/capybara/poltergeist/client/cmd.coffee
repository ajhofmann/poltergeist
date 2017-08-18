class Poltergeist.Cmd
  constructor: (@owner, @id, @name, @args)->
    @_response_sent = false
  sendResponse: (response) ->
    Promise.resolve(response).then (res)=>
      if !@_response_sent
        errors = @browser.currentPage.errors
        @browser.currentPage.clearErrors()

        if errors.length > 0 && @browser.js_errors
          @sendError(new Poltergeist.JavascriptError(errors))
        else
          @owner.sendResponse(@id, res)
          @_response_sent = true
    .catch (error) =>
      if error instanceof Poltergeist.Error
        @sendError(error)
      else
        @sendError(new Poltergeist.BrowserError(error.toString(), error.stack))
  sendError: (errors) ->
    if !@_response_sent
      @owner.sendError(@id, errors)
      @_response_sent = true

  run: (@browser) ->
    try
      Promise.resolve(@browser.runCommand(this)).catch (err)=>
        if err instanceof Poltergeist.Error
          @sendError(err)
        else
          @sendError(new Poltergeist.BrowserError(err.toString(), err.stack))
    catch error
      if error instanceof Poltergeist.Error
        @sendError(error)
      else
        @sendError(new Poltergeist.BrowserError(error.toString(), error.stack))

