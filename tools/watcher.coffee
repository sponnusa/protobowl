fs = require 'fs'
path = require 'path'
wrench = require 'wrench'
util = require 'util'
jade = require 'jade'
crypto = require 'crypto'
ws = require('websocket')
http = require 'http'

dev_port = 5577

server = http.createServer (req, res) ->
	res.writeHead 404
	res.end()

server.listen dev_port, ->
	console.log 'server is listening on ' + dev_port

updater = new ws.server {
	httpServer: server,
	autoAcceptConnections: true
}

connections = []

updater.on 'connect', (connection) ->
	connections.push connection

	connection.on 'close', ->
		connections = (c for c in connections when c isnt connection)
	
	# connection.sendUTF('rawr im a dinosaur')


send_update = -> 
	for c in connections
		c.sendUTF Date.now().toString()

# exports.watch = (fn) -> send_update = fn

less = require 'less'
	
Snockets = require 'snockets'
CoffeeScript = require 'coffee-script'

Snockets.compilers.coffee = 
	match: /\.js$/
	compileSync: (sourcePath, source) ->
		CoffeeScript.compile source, {filename: sourcePath, bare: true}

snockets = new Snockets()

recursive_build = (src, dest, cb) ->
	fs.stat dest, (err, deststat) ->
		# if !err
		# 	return wrench.rmdirRecursive dest, (err) ->
		# 		recursive_build src, dest, cb

		fs.stat src, (err, srcstat) ->
			return cb(err) if err
			fs.mkdir dest, srcstat.mode, (err) ->
				# return cb(err) if err
				fs.readdir src, (err, files) ->
					return cb(err) if err
					copyFiles = (err) ->
						return cb(err) if err
						filename = files.shift()
						return cb() if filename is null or typeof filename is 'undefined'
						
						file = src + '/' + filename
						destfile = dest + '/' + filename

						fs.stat file, (err, filestat) ->
							if filestat.isDirectory()
								recursive_build file, destfile, copyFiles
							else # no need to handle symbolic links
								fs.readFile file, (err, data) ->
									build_file filename, data, (outfile, output) ->
										fs.writeFile dest + '/' + outfile, output, copyFiles
					copyFiles()


build_file = (filename, data, callback) ->
	prefix = path.basename(filename, path.extname(filename))

	if path.extname(filename) is '.coffee'
		callback prefix + '.js', CoffeeScript.compile data.toString(), {filename: filename, bare: true}
	else
		callback filename, data




# simple helper function that hashes things
sha1 = (text) ->
	hash = crypto.createHash('sha1')
	hash.update(text + '')
	hash.digest('hex')




scheduledUpdate = null
path = require 'path'

# this is the new compilation procedure
# generate the folder structure and compile server components (straight coffee -> js compilation)
# compile the stylesheets 
# compile the HTML (jade -> html, js)
# compile the coffeescript and concatenate files
# compute hashes, save to disk
# compilation parameters: local, remote, debug, release



buildApplication = (target = null) ->
	source_list = []
	compile_date = new Date
	timehash = ''
	cache_text = ''

	settings = JSON.parse(fs.readFileSync('protobowl.json', 'utf8'))

	target = settings.target unless target
	
	opt = settings[target]

	console.log "Compiling for `#{target}` @ #{compile_date}"


	compileServer = ->
		recursive_build 'server', 'build/server', ->
			recursive_build 'shared', 'build/shared', ->
				beginCompile()

	beginCompile = ->
		fs.mkdir "build/#{target}", ->
			wrench.copyDirRecursive 'static', 'build/' + target, ->
				console.log 'compiling stylesheets'
				compileLess()

	compileLess = ->
		lessPath = 'client/less/protobowl.less'

		fs.readFile lessPath, 'utf8', (err, data) ->
			throw err if err

			parser = new(less.Parser)({
				paths: [path.dirname(lessPath)],
				filename: lessPath
			})

			parser.parse data, (err, tree) ->
				css = tree?.toCSS { compress: opt.less_compress }

				source_list.push {
					hash: sha1(css + ''),
					code: "/* protobowl_css_build_date: #{compile_date} */\n#{css}",
					err: err,
					file: "protobowl.css"
				}

				console.log 'compiling templates'
				compileJade()


	jade_list = (file.replace('.jade', '') for file in fs.readdirSync('client/jade') when /jade/.test(file))
	jade_src = ''

	compileJade = ->
		file = jade_list.shift()
		if !file
			fs.writeFile 'client/jade/_compiled.js', jade_src, 'utf8', (err) ->
				throw err if err
				console.log 'compiling application code'
				compileCoffee()
				
			return
		
		jadePath = "client/jade/#{file}.jade"
		
		fs.readFile jadePath, 'utf8', (err, data) ->

			throw err if err

			if file in ["app", "cacher"]
				# local = {
				# 	"static": "http://localhost:#{settings.dev.static_port}/",
				# 	"origin": "http://localhost:#{settings.dev.static_port}/",
				# 	"sockets": ["http://localhost:#{settings.dev.socket_port}/"]
				# }
				# remote = settings.deploy

				fn = jade.compile data, {
					pretty: opt.jade_pretty,
					filename: jadePath,
					compileDebug: opt.jade_debug
				}

				run_jade = (filename, options = {}) ->
					p = {}
					p[key] = val for key, val of opt
					p[key] = val for key, val of options
					try
						code = fn(p)
					catch e
						error = e

					source_list.push {
						hash: sha1(data)
						code: code
						err: error
						file: filename
					}

				run_jade "#{file}.html", { offline: false }
				if file is 'app'
					run_jade 'offline.html', { offline: true }
				
				compileJade()
			
			else
				fn = jade.compile data, {
					pretty: opt.jade_pretty,
					filename: jadePath,
					compileDebug: opt.jade_debug,
					client: true
				}
				
				jade_src += "//file: #{jadePath}\n\njade.#{file} = " + fn.toString() + "\n\n\n\n"

				compileJade()


	file_list = ['app', 'offline', 'auth']
	
	script_srcs = ''

	compileCoffee = ->
		file = file_list.shift()

		if !file
			return saveFiles() 

		snockets.getConcatenation "client/#{file}.coffee", minify: opt.js_minify, (err, js) ->
			code_contents = "protobowl_#{file}_build = '#{compile_date}';\n\n#{js}\n"

			if opt.js_wrap and file is 'app'
				code_contents = "protobowl_#{file}_build = '#{compile_date}';\n\n(function(){#{js}})();\n"

			source_list.push {
				hash: sha1(js + '')
				code:  code_contents 
				err: err
				file: "#{file}.js" 
			}

			compileCoffee()	
			

	saveFiles = ->		
		# clean up the jade stuff
		fs.unlink 'client/jade/_compiled.js', (err) ->
			throw err if err

		# its something like a unitard
		unihash = sha1((i.hash for i in source_list).join(''))
		if unihash is timehash# and force_update is false
			console.log 'files not modified'
			# compile_server()
			scheduledUpdate = null
			console.timeEnd("compile")
			return
		error_message = ''
			
		console.log 'saving files and updating manifest'
		for i in source_list
			error_message += "File: #{i.file}\n#{i.err}\n\n" if i.err
		if error_message
			send_update error_message
			console.log error_message
			scheduledUpdate = null
		else
			saved_count = 0
			for i in source_list
				# ensure that the target directories exist
				fs.writeFile "build/#{target}/#{i.file}", i.code, 'utf8', (err) ->
					throw err if err
					saved_count++
					if saved_count is source_list.length
						writeManifest(unihash)
						copyCache()

	copyCache = ->
		d = (name) -> "build/#{target}/#{name}"
		copy = (name) ->
			wrench.copyDirRecursive d(name), "build/#{target}/cache/#{name}", -> 1

		wrench.rmdirRecursive d('cache'), (err) ->
			fs.mkdirSync d 'cache'
			copy folder for folder in ['font', 'img', 'sound']

			# now copy over the files that are just kind of lying there
			fs.readdir "build/#{target}", (err, files) ->
				for file in files
					stat = fs.statSync "build/#{target}/#{file}"

					if stat.isFile()
						fs.createReadStream("build/#{target}/#{file}")
						.pipe fs.createWriteStream("build/#{target}/cache/#{file}")

	writeManifest = (hash) ->
		data = cache_text.replace(/INSERT_DATE.*?\r?\n/, 'INSERT_DATE '+compile_date + " # #{hash}\n")
		fs.writeFile "build/#{target}/offline.appcache", data, 'utf8', (err) ->
			throw err if err
			send_update()
			# compile_server()
			scheduledUpdate = null
			# clean up things
			console.timeEnd("compile")

	console.time("compile")
	fs.readFile 'client/protobowl.appcache', 'utf8', (err, data) ->
		cache_text = data

		fs.readFile "build/#{target}/offline.appcache", 'utf8', (err, data) ->
			timehash = data?.match(/INSERT_DATE (.*?)\n/)?[1]?.split(" # ")?[1]
			
			console.log 'compiling server components'
			compileServer()
			# compileLess()
		

do_update = ->
	return if scheduledUpdate
	scheduledUpdate = setTimeout ->
		buildApplication()
	, 100	

watcher = (event, filename) ->
	return if filename in ["_compiled.js"] or /tmp$/.test(filename)
	console.log "changed file", filename
	do_update(false)

force_watch = ->
	console.log 'forcing update'
	do_update(true)

console.log 'initializing filesystem listeners'

fs.watch "shared", watcher
fs.watch "client", watcher
fs.watch "client/less", watcher
fs.watch "client/lib", watcher
fs.watch "client/jade", watcher
fs.watch "protobowl.json", force_watch
fs.watch "server", watcher

fs.watch "protobowl.json", watcher

do_update()
