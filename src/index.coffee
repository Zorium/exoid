_ = require 'lodash'
Rx = require 'rxjs/Rx'
request = require 'clay-request'
stringify = require 'json-stable-stringify'

uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

module.exports = class Exoid
  constructor: ({@api, cache, @fetch}) ->
    cache ?= {}
    @fetch ?= request

    @_cache = {}
    @_batchQueue = []

    @cacheStreams = new Rx.ReplaySubject(1)
    @cacheStreams.next Rx.Observable.of @_cache
    @cacheStream = @cacheStreams.switch()

    _.map cache, @_cacheRefs

    _.map cache, (result, key) =>
      req = JSON.parse key

      isResource = uuidRegex.test req.path
      if isResource
        return null

      @_cacheSet key, @_streamResult req, result

  _cacheRefs: (result) =>
    unless @_isResultStreamable result
      throw new Error 'ids must be uuid'

    # top level refs only
    resources = if _.isArray(result) then result else [result]

    _.map resources, (resource) =>
      if resource?.id?
        key = stringify {path: resource.id}
        @_cacheSet key, Rx.Observable.of resource

  _isResultStreamable: (result) ->
    resources = if _.isArray(result) then result else [result]
    _.every resources, (resource) ->
      if resource?.id?
        uuidRegex.test resource.id
      else
        true

  _streamResult: (req, result) =>
    unless @_isResultStreamable result
      throw new Error 'ids must be uuid'

    resources = if _.isArray(result) then result else [result]
    refs = _.filter _.map resources, (resource) =>
      if resource?.id?
        @_cache[stringify {path: resource.id}].stream
      else
        null

    stream = (if _.isEmpty(refs) then Rx.Observable.of []
    else Rx.Observable.combineLatest(refs)
    ).switchMap (refs) =>
      # if a sub-resource is invalidated (deleted), re-request
      if _.some refs, _.isUndefined
        return @_deferredRequestStream req

      Rx.Observable.of \
      if _.isArray result
        _.map result, (resource) ->
          ref = _.find refs, {id: resource?.id}
          if ref? then ref else resource
      else
        ref = _.find refs, {id: result?.id}
        if ref? then ref else result

    return stream

  _deferredRequestStream: (req) =>
    cachedStream = null
    Rx.Observable.defer =>
      if cachedStream?
        return cachedStream

      return cachedStream = @_batchCacheRequest req

  _batchCacheRequest: (req) =>
    if _.isEmpty @_batchQueue
      setTimeout @_consumeBatchQueue

    resStreams = new Rx.ReplaySubject(1)
    @_batchQueue.push {req, resStreams}

    resStreams.switch()

  _updateCacheStream: =>
    stream = Rx.Observable.combineLatest _.map @_cache, ({stream}, key) ->
      stream.map (value) -> [key, value]
    .map (pairs) ->
      _.transform pairs, (cache, [key, val]) ->
        cache[key] = val
      , {}

    @cacheStreams.next stream

  getCacheStream: => @cacheStream

  _cacheSet: (key, stream) =>
    unless @_cache[key]?
      requestStreams = new Rx.ReplaySubject(1)
      @_cache[key] = {stream: requestStreams.switch(), requestStreams}
      @_updateCacheStream()

    @_cache[key].requestStreams.next stream

  _consumeBatchQueue: =>
    queue = @_batchQueue
    @_batchQueue = []

    @fetch @api,
      method: 'post'
      body:
        requests: _.pluck queue, 'req'
    .then (res) =>
      unless _.every res.results, @_isResultStreamable
        throw new Error 'ids must be uuid'
      return res
    .then ({results, cache, errors}) =>
      # update explicit caches from response
      _.map cache, ({path, body, result}) =>
        @_cacheSet stringify({path, body}), Rx.Observable.of result

      # update implicit caches from results
      _.map results, @_cacheRefs

      # update explicit request cache result, using ref-stream
      # top level replacement only
      _.map _.zip(queue, results, errors),
      ([{req, resStreams}, result, error]) =>
        if error?
          properError = new Error "#{JSON.stringify error}"
          resStreams.error _.defaults properError, error
        else
          resStreams.next @_streamResult req, result
    , (error) ->
      _.map queue, ({resStreams}) ->
        resStreams.error error
    .catch (err) -> console.error err # !unreachable

  getCached: (path, body) =>
    req = {path, body}
    key = stringify req

    if @_cache[key]?
      @_cache[key].stream.take(1).toPromise()
    else
      Promise.resolve null

  stream: (path, body) =>
    req = {path, body}
    key = stringify req

    if @_cache[key]?
      return @_cache[key].stream

    resourceKey = stringify {path: body}
    if _.isString(body) and uuidRegex.test(body) and @_cache[resourceKey]?
      resultPromise = @_cache[resourceKey].stream.take(1).toPromise()
      stream = Rx.Observable.defer ->
        resultPromise
      .switchMap (result) =>
        @_streamResult req, result
      @_cacheSet key, stream
      return @_cache[key].stream

    # Breaking change, returns cache if array of cached ids
    isCachedArrayIds = _.isArray(body) and _.every body, (id) =>
      uuidRegex.test(id) and @_cache[stringify {path: id}]
    if isCachedArrayIds
      resultPromises = _.map body, (id) =>
        @_cache[stringify {path: id}].stream.take(1).toPromise()
      stream = Rx.Observable.defer ->
        Promise.all resultPromises
      .switchMap (results) =>
        @_streamResult req, results
      @_cacheSet key, stream
      return @_cache[key].stream

    @_cacheSet key, @_deferredRequestStream req
    return @_cache[key].stream

  call: (path, body) =>
    req = {path, body}
    key = stringify req

    stream = @_deferredRequestStream req
    return stream.take(1).toPromise().then (result) =>
      @_cacheSet key, Rx.Observable.of result
      return result

  update: (result) =>
    @_cacheRefs result
    return null

  invalidateAll: =>
    _.map @_cache, ({requestStreams}, key) =>
      req = JSON.parse key
      if _.isString(req.path) and uuidRegex.test(req.path)
        return
      requestStreams.next @_deferredRequestStream req
    return null

  invalidate: (path, body) =>
    req = {path, body}
    key = stringify req
    resourceKey = stringify {path}

    if _.isString(path) and uuidRegex.test(path) and @_cache[resourceKey]?
      @_cache[resourceKey].requestStreams.next Rx.Observable.of(undefined)
      return null

    _.map @_cache, ({requestStreams}, cacheKey) =>
      req = JSON.parse cacheKey
      if _.isString(req.path) and uuidRegex.test(req.path)
        return

      if req.path is path and _.isUndefined body
        requestStreams.next @_deferredRequestStream req
      else if cacheKey is key
        requestStreams.next @_deferredRequestStream req
    return null
