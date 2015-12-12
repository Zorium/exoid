# Exoid

Interface with exoid compatible APIs

```coffee
Exoid = require 'exoid'
request = require 'clay-request'

@exoid = new Exoid
  api: config.API_URL + '/exoid'
  fetch: request

@exoid.stream 'games.getById', {id} # -> Observable
@exoid.call 'auth.login' # -> Promise
```
