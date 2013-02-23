assert   = require 'assert'
fs       = require 'fs'
path     = require 'path'
beholder = require '../lib/beholder'

maxFiles = 1000
pattern = path.join __dirname, 'fixtures/large/**/*'

arrayEqual = (a, b) ->
  a.length is b.length and a.every (elem, i) -> elem in b

describe 'Large filesets', ->

  before ->
    i = maxFiles
    while i--
      fs.writeFileSync path.join(__dirname, "fixtures/large/#{i}.txt"), "test"

  it 'should watch large filesets', (done) ->

    this.timeout(10000)

    beholder pattern, (err, watcher) ->
      assert.ifError err
      assert.equal maxFiles, watcher.list().length

      found = []
      files = watcher.list()

      watcher.on 'change', (fileName) ->
        found.push fileName

        if found.length is maxFiles
          watcher.removeAll()
          done()

      for file in watcher.list()
        fs.writeFileSync file, 'test'

  after ->
    i = 0
    while i < maxFiles
      fs.unlinkSync path.join(__dirname, "fixtures/large/#{i}.txt")
      i++