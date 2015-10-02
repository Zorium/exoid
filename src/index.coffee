_ = require 'lodash'
Rx = require 'rx-lite'
log = require 'loga'
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
    @cacheStreams.onNext Rx.Observable.just @_cache
    @cacheStream = @cacheStreams.switch()

    _.map cache, @_cacheRefs

    _.map cache, (result, key) =>
      req = JSON.parse key

      isResource = uuidRegex.test req.path
      if isResource
        return null

      @_cacheSet key, @_streamResult req, result

  _cacheRefs: (result) =>
    # top level refs only
    resources = if _.isArray(result) then result else [result]

    _.map resources, (resource) =>
      if resource?.id?
        unless uuidRegex.test resource.id
          throw new Error 'ids must be uuid'
        key = stringify {path: resource.id}
        @_cacheSet key, Rx.Observable.just resource

  _streamResult: (req, result) =>
    resources = if _.isArray(result) then result else [result]
    refs = _.filter _.map resources, (resource) =>
      if resource?.id?
        unless uuidRegex.test resource.id
          throw new Error 'ids must be uuid'
        @_cache[stringify {path: resource.id}].stream
      else
        null

    stream = (if _.isEmpty(refs) then Rx.Observable.just []
    else Rx.Observable.combineLatest(refs)
    ).flatMapLatest (refs) =>
      # if a sub-resource is invalidated (deleted), re-request
      if _.some refs, _.isUndefined
        return @_deferredRequestStream req

      Rx.Observable.just \
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

    @cacheStreams.onNext stream

  getCacheStream: => @cacheStream

  _cacheSet: (key, stream) =>
    unless @_cache[key]?
      requestStreams = new Rx.ReplaySubject(1)
      @_cache[key] = {stream: requestStreams.switch(), requestStreams}
      @_updateCacheStream()

    @_cache[key].requestStreams.onNext stream

  _consumeBatchQueue: =>
    queue = @_batchQueue
    @_batchQueue = []

    @fetch @api,
      method: 'post'
      body:
        requests: _.pluck queue, 'req'
    .then ({results, cache, errors}) =>
      # update explicit caches from response
      _.map cache, ({path, body, result}) =>
        @_cacheSet stringify({path, body}), Rx.Observable.just result

      # update implicit caches from results
      _.map results, @_cacheRefs

      # update explicit request cache result, using ref-stream
      # top level replacement only
      _.map _.zip(queue, results, errors),
      ([{req, resStreams}, result, error]) =>
        if error?
          return resStreams.onError error

        resStreams.onNext @_streamResult req, result
    .catch (err) ->
      log.error err

  stream: (path, body) =>
    req = {path, body}
    key = stringify req
    resourceKey = stringify {path: body}

    if @_cache[key]?
      return @_cache[key].stream

    if _.isString(body) and uuidRegex.test(body) and @_cache[resourceKey]?
      return @_cache[resourceKey].stream

    @_cacheSet key, @_deferredRequestStream req
    return @_cache[key].stream

  call: (path, body) =>
    @_deferredRequestStream {path, body}
    .take(1).toPromise()
