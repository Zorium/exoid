gulp = require 'gulp'
mocha = require 'gulp-mocha'
karma = require 'karma'
webpackStream = require 'webpack-stream'
coffeelint = require 'gulp-coffeelint'

paths =
  coffee: ['./src/**/*.coffee', './*.coffee', './test/**/*.coffee']
  tests: './test/**/*.coffee'
  rootScripts: './src/index.coffee'
  build: './build'
  output:
    tests: 'tests.js'

gulp.task 'test', ['test:lint', 'test:server', 'test:browser']

gulp.task 'watch', ->
  gulp.watch paths.coffee, ['test:server', 'test:browser']

gulp.task 'test:lint', ->
  gulp.src paths.coffee
    .pipe coffeelint()
    .pipe coffeelint.reporter()

gulp.task 'test:browser', ['scripts:test'], (cb) ->
  new karma.Server({
    singleRun: true
    frameworks: ['mocha']
    client:
      useIframe: true
      captureConsole: true
      mocha:
        timeout: 300
    files: [
      "#{paths.build}/#{paths.output.tests}"
    ]
    browsers: ['ChromeHeadless']
  }, cb).start()

gulp.task 'test:server', ->
  gulp.src paths.tests
    .pipe mocha
      compilers: 'coffee:coffee-script/register'
      timeout: 400
      useColors: true

gulp.task 'scripts:test', ->
  gulp.src paths.tests
  .pipe webpackStream
    devtool: '#inline-source-map'
    output:
      filename: paths.output.tests
    module:
      exprContextRegExp: /$^/
      exprContextCritical: false
      loaders: [
        {test: /\.coffee$/, loader: 'coffee-loader'}
      ]
    resolve:
      extensions: ['.coffee', '.js']
  .pipe gulp.dest paths.build
