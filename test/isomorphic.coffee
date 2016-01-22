require './polyfill'

_ = require 'lodash'
b = require 'b-assert'
log = require 'loga'
zock = require 'zock'
stringify = require 'json-stable-stringify'
request = require 'clay-request'

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
#     {path: '321', result: {id: '321'}}
#     {path: '321'} # invalidate
#     {path: 'users.all', body: {x: 'y'}, result: [{id: '123'}]} NOT IMPLEMENTED
#   ]
# }
###################################################################

UUIDS = [
  '2e6d9526-3df9-4179-b993-8de1029aea38'
  '60f752c3-4bdd-448a-a3c1-b18a55775daf'
  '97404ab5-40b4-4982-a596-218eb2457082'
]

it 'fetches data from remote endpoint, returning a stream', ->
  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    b body.requests.length, 1
    b body.requests[0].path, 'users.all'
    b body.requests[0].body, {x: 'y'}
    results: [
      [{id: UUIDS[0], name: 'joe'}]
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
      [{id: UUIDS[0], name: 'joe'}]
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
      [{id: UUIDS[0], name: 'joe'}]
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
      [{id: UUIDS[0], name: 'joe'}]
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
      [{id: UUIDS[0], name: 'joe'}]
      [{id: UUIDS[0], name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    stream = exo.stream 'users.all', {x: 'y'}
    # Must be different or else it will batch into one request
    call = exo.call 'users.allAlso', {x: 'y'}

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
        [{id: UUIDS[0], name: 'joe'}]
        {id: UUIDS[0], name: 'joe'}
      ]
      cache: [
        {path: UUIDS[1], result: {id: UUIDS[1], name: 'fry'}}
      ]
    else if body.requests[0].path is 'users.adminify'
      results: [{id: UUIDS[2], name: 'admin'}]
      cache: [
        {path: UUIDS[0], result: {id: UUIDS[0], name: 'joe-admin'}}
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    # stream should update when a child ref is updated
    streamChildren = exo.stream 'users', {x: 'y'}

    # stream should update when path is updated
    streamUser = exo.stream 'users', UUIDS[0]

    streamChildren.combineLatest streamUser
    .take(1).toPromise()
    .then ([children, user]) ->
      b children[0].name, 'joe'
      b user.name, 'joe'
      b requestCnt, 1
    .then ->
      exo.stream 'users.get', UUIDS[1]
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
        [{id: UUIDS[0], name: 'joe'}]
      ]
    else if body.requests[0].path is 'users.invalidate'
      results: [null]
      cache: [
        {path: UUIDS[0]}
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
      b err instanceof Error
      b err.status, '400'
  .then ->
    zock
    .post 'http://x.com/exoid'
    .reply 401
    .withOverrides ->
      exo = new Exoid({
        api: 'http://x.com/exoid'
      })

      exo.call 'users.all'
      .then ->
        throw new Error 'error expected'
      , (err) ->
        b err instanceof Error
        b err.status, 401

it 'does not propagate errors to streams', ->
  zock
  .post 'http://x.com/exoid'
  .reply 401
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    new Promise (resolve, reject) ->
      exo.stream 'users.all'
      .take(1).toPromise().then -> reject new Error 'Should not reject'

      setTimeout ->
        resolve null
      , 20
  .then ->
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

      new Promise (resolve, reject) ->
        exo.stream 'users.all'
        .take(1).toPromise().then -> reject new Error 'Should not reject'

        setTimeout ->
          resolve null
        , 20

it 'expsoes cache stream', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      [{id: UUIDS[0], name: 'joe'}]
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
      [{id: UUIDS[0], name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
      cache:
        "#{stringify {path: 'users', body: UUIDS[0]}}": {
          id: UUIDS[0]
          name: 'joe'
        }
    })

    exo.stream 'users', UUIDS[0]
    .take(1).toPromise()
    .then (user) ->
      b requestCnt, 0
      b user.name, 'joe'

it 'allows fetching values from cache', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    results: [null]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
      cache:
        "#{stringify {path: 'users', body: UUIDS[0]}}": {
          id: UUIDS[0]
          name: 'joe'
        }
    })

    exo.getCached 'users', UUIDS[0]
    .then (user) ->
      b requestCnt, 0
      b user.name, 'joe'

it 'watches refs when initialized from cache', ->
  requestCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    requestCnt += 1
    if requestCnt is 1
      results: [
        null
      ]
      cache: [
        {path: UUIDS[0], result: {id: UUIDS[0], name: 'joe-changed-1'}}
      ]
    else
      results: [
        {id: UUIDS[0], name: 'joe-changed-2'}
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
      cache:
        "#{stringify {path: 'users', body: UUIDS[0]}}": {
          id: UUIDS[0]
          name: 'joe'
        }
    })

    exo.stream 'users.get', UUIDS[0]
    .take(1).toPromise()
    .then (user) ->
      b requestCnt, 0
      b user.name, 'joe'
      exo.call 'users.mutate', UUIDS[0]
    .then (nulled) ->
      b nulled, null
      exo.stream 'users.get', UUIDS[0]
      .take(1).toPromise()
    .then (user) ->
      b requestCnt, 1
      b user.name, 'joe-changed-1'
      exo.call 'users.mutate', UUIDS[0]
    .then (user) ->
      b requestCnt, 2
      b user.name, 'joe-changed-2'
      exo.stream 'users.get', UUIDS[0]
      .take(1).toPromise()
    .then (user) ->
      b requestCnt, 2
      b user.name, 'joe-changed-2'

it 'allows custom fetch method to be passed in', ->
  exo = new Exoid({
    api: 'http://x.com/exoid'
    fetch: (url, opts) ->
      Promise.resolve
        results: [
          [{id: UUIDS[0], name: 'joe'}]
        ]
  })

  exo.stream 'users'
  .take(1).toPromise()
  .then (users) ->
    b users.length, 1
    b users[0].name, 'joe'

it 'handles data races', ->
  # TODO - correctness unclear, currently last-write wins
  null

it 'handles null results array', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      [null]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users, [null]

it 'handles null results value', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      null
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users, null

it 'handles non-resource results', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      ['a', 'b', 'c']
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users, ['a', 'b', 'c']

it 'enforces UUID ids', ->
  zock
  .post 'http://x.com/exoid'
  .reply ->
    results: [
      [{id: 'NOT_UUID', name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    promise = new Promise (resolve) ->
      isResolved = false
      log.on 'error', (err) ->
        unless isResolved?
          b err.message, 'ids must be uuid'
        isResolved = true
        resolve()

    exo.call 'users.all', {x: 'y'}

    return promise

it 'caches call responses', ->
  callCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ->
    callCnt += 1
    results: [
      [{id: UUIDS[0], name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.call 'users.all'
    .then (users) ->
      exo.stream 'users.all'
      .take(1).toPromise()
    .then (users) ->
      b callCnt, 1
      b users.length, 1
      b users[0].name, 'joe'

it 'invalidates all cached data', ->
  callCnt = 0
  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    callCnt += 1
    if callCnt > 1
      results: [
        [{id: UUIDS[0], name: 'jim'}]
      ]
    else
      results: [
        [{id: UUIDS[0], name: 'joe'}]
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.invalidateAll()
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'jim'

# TODO: improve tests around this
it 'invalidates resource by id', ->
  callCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    callCnt += 1
    if callCnt > 1
      results: [
        [{id: UUIDS[0], name: 'jim'}]
      ]
    else
      results: [
        [{id: UUIDS[0], name: 'joe'}]
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.invalidate(UUIDS[0])
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'jim'

it 'updates resources', ->
  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    results: [
      [{id: UUIDS[0], name: 'joe'}]
    ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.update({id: UUIDS[0], name: 'xxx'})
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'xxx'

it 'invalidates resources by path', ->
  callCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    callCnt += 1
    if callCnt > 1
      results: [
        [{id: UUIDS[0], name: 'jim'}]
      ]
    else
      results: [
        [{id: UUIDS[0], name: 'joe'}]
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.invalidate 'users.all'
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'jim'

it 'invalidates resources by path and body', ->
  callCnt = 0

  zock
  .post 'http://x.com/exoid'
  .reply ({body}) ->
    callCnt += 1
    if callCnt > 1
      results: [
        [{id: UUIDS[0], name: 'jim'}]
      ]
    else
      results: [
        [{id: UUIDS[0], name: 'joe'}]
      ]
  .withOverrides ->
    exo = new Exoid({
      api: 'http://x.com/exoid'
    })

    exo.stream 'users.all', {x: 'y'}
    .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.invalidate 'users.all', {x: 'NOT_Y'}
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'joe'
      exo.invalidate 'users.all', {x: 'y'}
      exo.stream 'users.all', {x: 'y'}
      .take(1).toPromise()
    .then (users) ->
      b users[0].name, 'jim'
