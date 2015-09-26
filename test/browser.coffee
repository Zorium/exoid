b = require 'b-assert'

example = require '../src'

browserIt = if window? then it else (-> null)

browserIt 'browser compares equals', ->
  unless window?
    throw new Error 'Only works in browsers'
  res = example.compare 'a', 'a'
  b res, true
