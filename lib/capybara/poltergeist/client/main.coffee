
class Poltergeist
  constructor: (port, width, height, host) ->
    @browser = new Poltergeist.Browser(width, height)
    @browser.launch().then =>
      @connection = new Poltergeist.Connection(this, port, host)
      console.log "browser launched and connection created"
    # phantom.onError = (message, stack) => @onError(message, stack)

  runCommand: (command) ->
    new Poltergeist.Cmd(this, command.id, command.name, command.args).run(@browser)

  sendResponse: (command_id, response) ->
    this.send(command_id: command_id, response: response)

  sendError: (command_id, error) ->
    this.send(
      command_id: command_id,
      error:
        name: error.name || 'Generic',
        args: error.args && error.args() || [error.toString()]
    )

  send: (data) ->
    @connection.send(data)
    return true

# This is necessary because the remote debugger will wrap the
# script in a function, causing the Poltergeist variable to
# become local.
global.Poltergeist = Poltergeist

class Poltergeist.Error

class Poltergeist.ObsoleteNode extends Poltergeist.Error
  name: "Poltergeist.ObsoleteNode"
  args: -> []
  toString: -> this.name

class Poltergeist.InvalidSelector extends Poltergeist.Error
  constructor: (@method, @selector) -> super()
  name: "Poltergeist.InvalidSelector"
  args: -> [@method, @selector]

class Poltergeist.FrameNotFound extends Poltergeist.Error
  constructor: (@frameName) -> super()
  name: "Poltergeist.FrameNotFound"
  args: -> [@frameName]

class Poltergeist.MouseEventFailed extends Poltergeist.Error
  constructor: (@eventName, @selector, @position) -> super()
  name: "Poltergeist.MouseEventFailed"
  args: -> [@eventName, @selector, @position]

class Poltergeist.KeyError extends Poltergeist.Error
  constructor: (@message) -> super()
  name: "Poltergeist.KeyError"
  args: -> [@message]

class Poltergeist.JavascriptError extends Poltergeist.Error
  constructor: (@errors) -> super()
  name: "Poltergeist.JavascriptError"
  args: -> [@errors]

class Poltergeist.BrowserError extends Poltergeist.Error
  constructor: (@message, @stack) -> super()
  name: "Poltergeist.BrowserError"
  args: -> [@message, @stack]

class Poltergeist.StatusFailError extends Poltergeist.Error
  constructor: (@url, @details) -> super()
  name: "Poltergeist.StatusFailError"
  args: -> [@url, @details]

class Poltergeist.NoSuchWindowError extends Poltergeist.Error
  name: "Poltergeist.NoSuchWindowError"
  args: -> []

class Poltergeist.UnsupportedFeature extends Poltergeist.Error
  constructor: (@message) -> super()
  name: "Poltergeist.UnsupportedFeature"
  args: -> [@message, "phantom.version"]

browser = require("./browser.js")
connection = require("./connection.js")
cmd = require("./cmd.js")

new Poltergeist(process.argv.slice(2)...)
