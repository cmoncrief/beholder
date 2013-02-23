# beholder
# Copyright (c) 2013 Charles Moncrief <cmoncrief@gmail.com>
# MIT Licensed

{EventEmitter} = require 'events'
fs             = require 'fs'
path           = require 'path'
async          = require 'async'
glob           = require 'glob'
minimatch      = require 'minimatch'

class Beholder extends EventEmitter

  # Main entry point. Set up the options and initiate watching the
  # supplied pattern
  constructor: (@pattern, @options = {}, cb) ->

    @files = []
    @dirs = []
    @patterns = []

    @init = true
    @options.interval ?= 5007
    @options.persistent ?= true
    @options.includeHidden ?= false
    @options.exclude ?= []
    @pollOpts = {interval: @options.interval, persistent: @options.persistent}

    @startWatch @pattern, cb

  #
  # Private API Functions
  #

  # Start watching a given pattern. Invokes callback if supplied, and pauses
  # briefly to give things time to settle down if needed.
  startWatch: (pattern, cb) ->

    if process.platform is 'win32'
      pattern = pattern.replace(new RegExp('\\'), '/')

    @patterns.push pattern

    glob pattern, (err, matches) =>

      if pattern.indexOf '*' isnt -1
        @addDir pattern.replace /\/\*.*/, ''

      async.each matches, @processPath, (err) =>
        
        return cb(err) if err and cb
        return handleError(err) if err

        @init = false
        finish = => 
          cb(null, this) if cb
          @emit 'ready'

        setTimeout(finish, matches.length)

  # Traverse a directory path looking for items to watch. Called recursively via
  # a sub function. This is only run when a directory receives a change event.
  walkPath: (base) =>

    fs.stat base, (err, stats) =>
      return if err?.code is 'ENOENT'
      return @handleError(err) if err

      if stats.isDirectory()
        @addDir base
        fs.readdir base, (err, files) =>
          return if err?.code is 'ENOENT'
          return @handleError(err) if err

          @processPath(path.join(base, file), null, true) for file in files
          return

      else
        @addFile base, stats

  # Evaluates a given path and adds it to the appropriate watcher list.
  processPath: (filePath, cb, descend) =>

    fs.stat filePath, (err, stats) =>
      return @handleError(err, true) if err

      if stats.isDirectory()
        @addDir filePath
        @walkPath filePath if descend
      else
        @addFile filePath, stats, @init

      cb() if cb

  # Adds a directory to the watch list
  addDir: (dirPath) ->

    return if @hiddenPath(dirPath)
    return if dirPath in (i.name for i in @dirs)

    @dirs.push {name: dirPath, watch: @initWatch(dirPath, @processDir)}

  # Adds a file to the watch list.
  addFile: (filePath, stats, silent) =>

    return if @invalidFile filePath

    @files.push
      name: filePath
      mtime: stats.mtime
      watcher: @initWatch(filePath, @processFile)

    @processFile(filePath, 'new') unless silent

    if path.dirname(filePath) not in (i.name for i in @dirs)
      @addDir path.dirname(filePath)
  
  # Start watching a given path. Handles switching between watching and 
  # polling depending on the current number of watchers.
  initWatch: (watchPath, watchFn) =>

    if @maxFiles? and @files.length >= @maxFiles
      return @initPoll(watchPath, watchFn)

    try
      fs.watch path.normalize(watchPath), @pollOpts, (event, filename) =>
        watchFn watchPath, event
    catch err
      if err.code is 'EMFILE'
        @maxFiles = @files.length
        @swapWatchers()
        @initPoll watchPath, watchFn
      else @handleError(err)

  # Start polling a given path.
  initPoll: (watchPath, watchFn) ->
    
    fs.watchFile path.normalize(watchPath), (curr, prev) =>
      return if curr.mtime.getTime() and curr.mtime.getTime() < prev.mtime.getTime()
      watchFn watchPath, 'change' 

  # Handle a raised event on a watched directory by traversing its path
  # and looking for changes.
  processDir: (dir, event) =>

    @walkPath dir

  # Handle a raised event on a watched file. After handling the event, removes
  # the watcher and restarts it of rmemory handling purposes.
  processFile: (filePath, event) =>

    file = i for i in @files when i.name is filePath

    fs.stat filePath, (err, stats) =>
      return @removeWatch(file) if err?.code is 'ENOENT'
      return @handleError(err) if err
      return if event isnt 'new' and stats.mtime.getTime() is file.mtime.getTime()

      file.mtime = stats.mtime

      @emit 'any', filePath, event
      @emit event, filePath

      @removeWatch filePath, true
      @addFile filePath, stats, true

      file = null
      filePath = null
      event = null

    return

  # Stop watching a file.
  removeWatch: (file, silent) =>

    if file.watcher?.close?
      file.watcher.close()
    else
      fs.unwatchFile file.name

    @files = (i for i in @files when i.name isnt file.name)
    @dirs = (i for i in @dirs when i.name isnt file.name)
    @emit('remove', file.name) unless silent
    @emit('any', file.name) unless silent
    file.watcher = null
    file = null

  # When the maximum number of files has been hit, this function
  # will swap out several watchers for pollers in order to create
  # available file handler headroom.
  swapWatchers: =>

    for file, index in @files when index > @maxFiles - 25
      file.watcher.close() if file.watcher.close
      file.watcher = null
      file.watcher = @initPoll file.name, @processFile

    return

  # Returns true if this file should not be added to the watch list
  invalidFile: (filePath) =>
    
    return true if @hiddenPath(filePath)
    return true if filePath in (i.name for i in @files)
    return true unless @patternMatch(filePath)
    (return true if minimatch filePath, i) for i in @options.exclude

    return false

  # Returns true if the file matches at least one of the stored patterns.
  patternMatch: (filePath) ->
    
    for pattern in @patterns
      return true if minimatch(filePath, pattern)
    return false

  # Returns true if this is a hidden dotfile.
  hiddenPath: (filePath) =>

    path.basename(filePath)[0] is '.' and !@options.includeHidden

  # Emits the error event and returns the error
  handleError: (error) =>

    @emit 'error', error
    error

  #
  # Public API Functions
  #

  # Remove a specified file path from the watch list.
  remove: (filePath, silent) =>

    file = i for i in @files when i.name is filePath
    unless file then file = i for i in @dirs when i.name is filePath 
    return console.log(new Error("File not found")) unless file

    @removeWatch file, silent

  # Remove all files from the watch list.
  removeAll: (silent) =>

    @removeWatch file, silent for file in @files
    return

  # Add new paths to the watch list that match pattern
  add: (pattern, cb) =>

    @startWatch pattern, cb

  # Returns an array of all file names on the watch list
  list: =>

    (i.name for i in @files)

  # Returns an array of all directory names on the watch list
  listDir: =>

    (i.name for i in @dirs)

# Main entry point. Returns a new instance of Beholder.
module.exports = (pattern, options, cb) ->

  if !cb and typeof options is 'function'
    cb = options
    options = {}

  new Beholder(pattern, options, cb)

