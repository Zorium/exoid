b = require 'b-assert'

example = require '../src'

serverIt = if window? then (-> null) else it

serverIt 'server compares equals', ->
  if window?
    throw new Error 'This test only runs on the server'
  res = example.compare 'a', 'a'
  b res, true
