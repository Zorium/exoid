_ = require 'lodash'
b = require 'b-assert'
zock = require 'zock'
stringify = require 'json-stable-stringify'

Exoid = require '../src'

#################################################################
# Exoid Protocol
#
# # request
# {
#   requests: [
#     {path: 'users', body: '123'}
#     {path: 'users.all', body: {x: 'y'}}
#   ]
# }
# # response
# {
#   results: [
#     {id: '123'}
#     [{id: '123'}]
#   ]
#   errors: [null, null]
# }
# # or with cache update / invalidation
# {
#   results: [
#     {id: '123'}
#     [{id: '123'}]
#   ]
#   cache: [
#     {path: 'users', body: '321', result: {id: '321'}}
#     {path: 'users', body: '321', result: null}
#   ]
# }
###################################################################

it 'fetches data from remote endpoint, returning a stream', ->
  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    b body.requests.length, 1
    b body.requests[0].path, 'users.all'
    b body.requests[0].body, {x: 'y'}
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users.length, 1
      b users[0].name, 'joe'

it 'calls rpc on remote endpoint, returning a promise', ->
  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    b body.requests.length, 1
    b body.requests[0].path, 'users.all'
    b body.requests[0].body, {x: 'y'}
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.call 'users.all', {x: 'y'}
    .then (users) ->
      b users.length, 1
      b users[0].name, 'joe'

it 'caches streams', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    stream1 = exo.stream 'users.all', {x: 'y'}
    stream2 = exo.stream 'users.all', {x: 'y'}
    b stream1, stream2

    stream1.combineLatest(stream2).take(1).toPromise()
    .then ->
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      b requestCnt, 1

it 'doesnt cache calls', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.call 'users.all', {x: 'y'}
    .then ->
      exo.call 'users.all', {x: 'y'}
    .then (users) ->
      b users[0].name, 'joe'
      b requestCnt, 2

it 'batches requests', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    results: [
      [{id: '123', name: 'joe'}]
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    stream = exo.stream 'users.all', {x: 'y'}
    call = exo.call 'users.all', {x: 'y'}

    stream.take(1).toPromise()
    .then -> call
    .then (users) ->
      b users[0].name, 'joe'
      b requestCnt, 1

it 'uses resource cache', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    requestCnt += 1
    if body.requests[0].path is 'users'
      results: [
        [{id: '123', name: 'joe'}]
        {id: '123', name: 'joe'}
      ]
      cache: [
        {path: 'users', body: '321', result: {id: '321', name: 'fry'}}
      ]
    else if body.requests[0].path is 'users.adminify'
      results: [{id: 'xxx', name: 'admin'}]
      cache: [
        {path: 'users', body: '123', result: {id: '123', name: 'joe-admin'}}
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    # stream should update when a child ref is updated
    streamChildren = exo.stream 'users', {x: 'y'}

    # stream should update when path is updated
    streamUser = exo.stream 'users', '123'

    streamChildren.combineLatest streamUser
    .take(1).toPromise()
    .then ([children, user]) ->
      b children[0].name, 'joe'
      b user.name, 'joe'
      b requestCnt, 1
    .then ->
      exo.stream 'users', '321'
      .take(1).toPromise()
      .then (fry) ->
        b requestCnt, 1
        b fry.name, 'fry'
    .then ->
      exo.call 'users.adminify'
    .then (admin) ->
      b admin.name, 'admin'
      b requestCnt, 2
    .then ->
      streamChildren.combineLatest streamUser
      .take(1).toPromise()
      .then ([children, user]) ->
        b children[0].name, 'joe-admin'
        b user.name, 'joe-admin'
        b requestCnt, 2

it 'invalidates resource, causing re-fetch of streams', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    requestCnt += 1
    if body.requests[0].path is 'users'
      results: [
        [{id: '123', name: 'joe'}]
      ]
    else if body.requests[0].path is 'users.invalidate'
      results: [null]
      cache: [
        {path: 'users', body: '123', result: null}
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      b requestCnt, 1
    .then ->
      exo.call 'users.invalidate'
    .then ->
      b requestCnt, 2
      exo.stream 'users', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      b requestCnt, 3

# Note: if streaming errors are needed could add .streamErrors()
it 'handles errors', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      null
    ]
    errors: [
      {status: '400'}
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.call 'users.all'
    .then ->
      throw new Error 'Expected error'
    , (err) ->
      b err.status, '400'
    .then ->
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
      .then ->
        throw new Error 'Expected error'
      , (err) ->
        b err.status, '400'


it 'expsoes cache stream', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    cache = exo.getCacheStream()

    cache.take(1).toPromise()
    .then (cache) ->
      b cache, {}
    .then ->
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then ->
      cache.take(1).toPromise()
    .then (cache) ->
      b _.isPlainObject cache
      b _.keys(cache).length, 2
    .then ->
      exo.stream 'users.next'
      .take(1).toPromise()
    .then ->
      cache.take(1).toPromise()
    .then (cache) ->
      b _.isPlainObject cache
      b _.keys(cache).length, 3

it 'allows initializing from cache', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    results: [
      [{id: '123', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
      cache:
        "#{stringify {path: 'users', body: '123'}}": {id: '123', name: 'joe'}
    })

    exo.stream 'users', '123'
    .take(1).toPromise()
    .then (user) ->
      b requestCnt, 0
      b user.name ,'joe'

it 'allows custom fetch method to be passed in', ->
  # TODO
  null

it 'handles data races', ->
  # TODO
  null

it 'handles null results', ->
  # TODO
  null

it 'handles non-resource results', ->
  # TODO
  null

it 'caches just on uuid', ->
  # TODO
  null
