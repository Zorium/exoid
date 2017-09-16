# Exoid

Interface with exoid compatible APIs

Depends on `Promise()` and `fetch()`

```coffee
Exoid = require 'exoid'
request = require 'iso-request'

@exoid = new Exoid
  api: config.API_URL + '/exoid'
  fetch: request

@exoid.stream 'games.getById', {id} # -> Observable
@exoid.call 'auth.login' # -> Promise
```
