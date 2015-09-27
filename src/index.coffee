_ = require 'lodash'
Rx = require 'rx-lite'
request = require 'clay-request'
stringify = require 'json-stable-stringify'

module.exports = class Exoid
  constructor: ({@api, cache, @fetch}) ->
    cache ?= {}
    @fetch ?= request

    @_cache = {}
    @_batchQueue = []

    @cacheStreams = new Rx.ReplaySubject(1)
    @cacheStreams.onNext Rx.Observable.just @_cache
    @cacheStream = @cacheStreams.switch()

    _.map cache, (value, key) =>
      @_cacheSet key, Rx.Observable.just value

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
        req = {path, body}
        key = stringify req

        @_cacheSet key, \
          if result? then Rx.Observable.just result
          else @_deferredRequestStream req

      # update implicit (ref-based) resource cache from results
      # top level refs only
      _.map _.zip(queue, results), ([{req}, result]) =>
        rootPath = req.path.split('.')[0]
        resources = if _.isArray(result) then result else [result]

        _.map resources, (resource) =>
          unless resource?.id?
            return

          key = stringify {path: rootPath, body: resource.id}
          @_cacheSet key, Rx.Observable.just resource

      # update explicit request cache result, using ref-stream
      # top level replacement only
      _.map _.zip(queue, results, errors),
      ([{req, resStreams}, result, error]) =>
        if error?
          return resStreams.onError error

        rootPath = req.path.split('.')[0]
        key = stringify req

        isBaseResource = req.path is rootPath and req.body is result?.id
        if isBaseResource
          resStreams.onNext Rx.Observable.just result
          return

        resources = if _.isArray(result) then result else [result]
        refs = _.filter _.map resources, (resource) =>
          if resource?.id?
            @_cache[stringify {path: rootPath, body: resource.id}].stream
          else
            null

        resStreams.onNext \
        (if _.isEmpty(refs) then Rx.Observable.just []
        else Rx.Observable.combineLatest(refs)
        ).map (refs) ->
          if _.isArray result
            _.map result, (resource) ->
              ref = _.find refs, {id: resource?.id}
              if ref? then ref else resource
          else
            ref = _.find refs, {id: result?.id}
            if ref? then ref else result

    .catch (err) ->
      setTimeout ->
        throw err

  stream: (path, body) =>
    req = {path, body}
    key = stringify req

    if @_cache[key]?
      return @_cache[key].stream

    @_cacheSet key, @_deferredRequestStream req
    return @_cache[key].stream

  call: (path, body) =>
    @_deferredRequestStream {path, body}
    .take(1).toPromise()
