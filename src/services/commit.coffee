#TODO: hooks
Busboy = require "busboy"
Promise = require "bluebird"
_path = require "path"
{httpify} = require "../helpers"
os = require "os"
{createWriteStream} = require "fs"
rimraf = Promise.promisify require "rimraf"
mkdirp = Promise.promisify require "mkdirp"
git = require "../ezgit"

module.exports = (app, options) ->
	{ConflictError, BadRequestError} = app.errors

	app.post "/:reponame(.*).git/:refname(.*)?/commit/:path(.*)?", app.authorize("commit"), (req, res, next) ->
		{hook, using, open} = req.git
		{reponame, refname, path} = req.params
		etag = req.headers['x-parent-id'] or req.query?.parent or "#{git.Oid.ZERO}"
		repo = open reponame
		ref = repo.then (repo) ->
				git.Reference.find repo, refname
			.then using
			.then (ref) ->
				if ref?.isSymbolic()
					refname = ref.symbolicTarget()
					return null
				else if ref?
					refname = ref.name()
				ref
			.catch httpify 404

		checkref = ->
			ref.then (ref) ->
				if ref? and "#{ref.target()}" isnt etag
					throw new ConflictError
				ref

		parent = Promise.join repo, ref, (repo, ref) ->
			if ref? then repo.getCommit ref.target() else null
		.then using

		tree = parent
			.then (commit) -> commit?.getTree()
			.then using
			.then (tree) ->
				return tree unless path
				tree?.entryByPath path
				.then using
				.then (entry) ->
					if entry.isBlob()
						throw new BadRequestError()
					tree

		index = Promise.join repo, tree, (repo, tree) ->
			repo.index()
			.then using
			.then (index) ->
				index.clear()
				if tree
					index.readTree tree
				index

		workdir = _path.join os.tmpdir(), "express-git-#{new Date().getTime()}"
		Promise.join repo, parent, index, mkdirp(workdir), (repo, parent, index) ->
			repo.setWorkdir workdir, 0
			bb = new Busboy headers: req.headers
			files = []
			add = []
			bb.on "file", (filepath, file) ->
				filepath = _path.join (path or ""), filepath
				dest = _path.join workdir, filepath
				files.push new Promise (resolve, reject) ->
					file.on "end", ->
						add.push filepath
						resolve()
					file.on "error", reject
					file.pipe createWriteStream dest

			commit = {}
			remove = []
			bb.on "field", (fieldname, value) ->
				if fieldname is "remove"
					remove.push value
				else
					commit[fieldname] = value

			finish = new Promise (resolve) -> bb.on "finish", -> resolve()
			req.pipe bb
			finish
			.then -> Promise.all files
			.then ->
				for r in remove
					index.removeByPath r
				for a in add
					index.addByPath a
				index.writeTree()
			.finally -> index.clear()
			.then (tree) -> repo.getTree tree
			.then using
			.then (tree) ->
				author =
					if commit.author
					then git.Signature.create commit.author, new Date commit.created_at
					else repo.defaultSignature()
				committer =
					if commit.committer
					then git.Signature.create commit.committer, new Date()
					else git.Signature.create author, new Date()
				parents: [parent]
				tree: tree
				author: author.toJSON()
				commiter: committer.toJSON()
				message: message.toJSON()
			.then (commit) ->
				hook 'pre-commit', repo, commit
				.then -> checkref()
				.then -> repo.commit assign {}, commit, ref: null
				.then using
				.then (commit) ->
					signature = commit.committer()
					message = commit.message()
					id = commit.id()
					hook 'update', repo,
						after: "#{id}"
						before: etag
						ref: refname
					.then -> ref
					.then (ref) ->
						if ref?
							ref.setTarget id, signature, message
						else
							git.Reference.create repo, refname, id, 0, signature, message
					.then using
					.then (ref) ->
						hook 'post-receive', [
							{before: etag, after: "#{ref.target()}", ref: "#{ref.name()}"}
						]
				.then commit
		.then (commit) -> next null, res.json commit
		.catch next
		.finally -> rimraf workdir
		.catch -> null
