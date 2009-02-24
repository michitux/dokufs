#!/usr/bin/ruby
# DokuFS
# A Filesystem for accessing DokuWiki (version 2009-02-14 or above)
# on your local filesystem. More information can be found on 
# http://www.content-space.de/go/dokufs
#
# Copyright (C) 2009  Michael Hamann  michael <at> content-space.de

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# The idea of this program and some of the recursive functions here
# are adapted versions of MetaFS which was written by Greg Millam and
# distributed with FuseFS. Besides Ruby this FuseFS which can be
# obtained on http://rubyforge.org/projects/fusefs/ is the only
# dependency of DokuFS.

# TODO: recognize when save failed

require "cgi"
require "fusefs"
require "xmlrpc/client"
require "optparse"

class StringCache < Hash
	def initialize (maxsize)
		super()
		@maxsize = maxsize
		@lru_keys = []
	end

	def clear
		super
		@lru_keys.clear
	end

	def []= (key, value)
		raise ArgumentError, "Value must be kind of String" unless value.kind_of?(String)
		remove_lru
		super
		touch key
	end

	def merge! (hash)
		hash.each { |k,v| self[k] = v }
	end

	def delete (key)
		value = super
		@lru_keys.delete key
		value
	end

	protected

	def touch (key)
		@lru_keys.delete key
		@lru_keys << key
	end

	def mem_size
		result = 0
		each_value do |v|
			result += v.size
		end
		return result
	end

	def remove_lru
		while mem_size >= @maxsize
			key = @lru_keys.delete_at 0
			delete key
		end
	end
end

class DokuFS < FuseFS::FuseDir
	AUTH_NONE = 0
	AUTH_READ = 1
	AUTH_EDIT = 2
	AUTH_CREATE = 4
	AUTH_UPLOAD = 8
	AUTH_DELETE = 16
	AUTH_ADMIN = 255

	DEFAULT_OPTS = {
		:use_ssl => true,
		:path => "/lib/exe/xmlrpc.php",
		:host => "localhost"
	}

	def root?
		@is_root
	end

	def media?
		@is_media
	end

	def use_cache?
		@use_cache
	end

	def initialize(user_opts = nil)
		@pages = {}
		@subdirs = {}
		if ! user_opts.nil?
			opts = DEFAULT_OPTS
			opts.merge!(user_opts)
			opts[:path] += "?u=#{CGI.escape(opts[:user])}&p=#{CGI.escape(opts[:password])}" if opts[:user] && opts[:password]
			@server = XMLRPC::Client.new3(opts)
			@is_root = true
			@is_media = opts[:media]
			@use_cache = !opts[:nocache] && !@is_media
			unless self.media?
				@cache = StringCache.new(1024*1024*5) if @use_cache
				@server.call("wiki.getAllPages").each do |page|
					self.add(pagename_to_path(page['id']), page)
					# set the last-update-timestamp to the most recently updated page
					# as we can't rely that the local time is in sync with server time
					if (!@last_update || @last_update < page['lastModified'].to_time)
						@last_update = page['lastModified'].to_time
					end
				end
			else
				@server.call("wiki.getAttachments", "", {:recursive => true}).each do |media|
					self.add(pagename_to_path(media['id']), media)
					if (!@last_update || @last_update < media['lastModified'].to_time)
						@last_update = media['lastModified'].to_time
					end
				end
			end
			@last_update ||= Time.now.utc.to_i
		end
	end

	def add(path, data)
		base, rest = split_path(path)
		case
		when base.nil?
			return false
		when rest.nil?
			@pages[base] = data
		when @subdirs.has_key?(base)
			@subdirs[base].add(rest, data)
		else
			(@subdirs[base] = self.class.new).add(rest, data)
		end
	end

	def getdata(path)
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			if @pages.has_key?(base)
				return @pages[base]
			else
				return false
			end
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].getdata(rest)
		end
	end

	def contents(path)
		base, rest = split_path(path)
		case
		when base.nil?
			(@pages.keys + @subdirs.keys).sort.uniq
		when ! @subdirs.has_key?(base)
			nil
		when rest.nil?
			@subdirs[base].contents('/')
		else
			@subdirs[base].contents(rest)
		end
	end

	def size(path)
		if directory?(path)
			return 4000
		else
			if file?(path)
				return getdata(path)['size']
			end
		end
	end

	def directory?(path)
		base, rest = split_path(path)
		case
		when base.nil?
			true
		when ! @subdirs.has_key?(base)
			false
		when rest.nil?
			true
		else
			@subdirs[base].directory?(rest)
		end
	end

	def file?(path)
		if (self.root? && ! self.media? && self.use_cache?)
			return true if @cache.has_key?(path_to_pagename(path))
		end
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			@pages.has_key?(base)
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].file?(rest)
		end
	end

	def can_write? path
		if file?(path)
			perms = getdata(path)['perms']
			if media?
				return perms >= AUTH_DELETE
			else
				return perms >= AUTH_EDIT
			end
		else
			if media?
				perms = @server.call('wiki.aclCheck', path_to_pagename(path)) 
				return perms >= AUTH_UPLOAD
			else
				return false unless path =~ /\.dw\Z/
				perms = @server.call('wiki.aclCheck', path_to_pagename(path)) 
				return perms >= AUTH_CREATE
			end
		end
	end

	# mkdir
	def can_mkdir? path
		return true
	end

	def mkdir(path)
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			@subdirs[base] = self.class.new
			true
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].mkdir(rest)
		end
	end

	# Delete a file
	def can_delete?(path)
		#return false unless Process.uid == FuseFS.reader_uid
		if file?(path)
			perms = getdata(path)['perms']
			if media?
				return perms >= AUTH_DELETE
			else
				return perms >= AUTH_EDIT
			end
		else
			return false
		end
	end

	def remove_from_tree(path)
		base, rest = split_path(path)
		case
		when base.nil?
			nil
		when rest.nil?
			# Delete it.
			@pages.delete(base)
		when ! @subdirs.has_key?(base)
			nil
		else
			@subdirs[base].remove_from_tree(rest)
		end
	end

	def delete(path)
		if media?
			@server.call("wiki.deleteAttachment", path_to_pagename(path))
		else
			@server.call("wiki.putPage", path_to_pagename(path), "", { "sum" => "deleted by DokuFS", "minor" => false })
			@cache.delete(path_to_pagename(path)) if self.use_cache?
		end
		self.remove_from_tree(path)
	end


	# Delete an existing directory.
	def can_rmdir?(path)
		#return false unless Process.uid == FuseFS.reader_uid
		base, rest = split_path(path)
		if base.nil?
			@pages.empty?
		else
			if @subdirs.has_key?(base)
				if rest.nil?
					@subdirs[base].can_rmdir?("/")
				else
					@subdirs[base].can_rmdir?(rest)
				end
			else
				false
			end
		end
	end
	def rmdir(path)
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			@subdirs.delete(base)
			true
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].rmdir(rest)
		end
	end

	def read_file path
		pagename = path_to_pagename(path)
		begin 
			if media?
				XMLRPC::Base64.decode(@server.call("wiki.getAttachment", pagename))
			else
				if (self.use_cache?)
					@cache[pagename] ||= @server.call("wiki.getPage", pagename)
				else
					@server.call("wiki.getPage", pagename)
				end
			end
		rescue XMLRPC::FaultException => e
			return ""
		end
	end

	def write_to (path, content)
		pagename = path_to_pagename(path)
		if media?
			begin
				encoded_content = XMLRPC::Base64.encode(content)
				@server.call("wiki.putAttachment", pagename, encoded_content, {:overwrite => self.file?(path)})
				data = {
					'id' => path_to_pagename(path),
					'size' => content.size,
					'perms' => @server.call('wiki.aclCheck', path_to_pagename(path)),
				}
				self.add(path, data)
			rescue Exception => e
				puts e.message
			end
		else
			message = { "sum" => "", "minor" => true }
			plain_content = content
			if content[0] == "%"[0]
				content.sub!(/\A%\s?([^\n]+)\n?/m) do
					message["sum"] = $1
					""
				end
				message["minor"] = false
			end
			if content =~ /\A\s*\Z/m # when the page is empty, it is deleted
				if message["sum"].empty?
					return false
				end
				self.remove_from_tree(path)
			else
				data = {
					'id' => path_to_pagename(path),
					'size' => plain_content.size,
					'perms' => @server.call('wiki.aclCheck', path_to_pagename(path)),
				}
				self.add(path, data)
			end
			@cache[pagename] = plain_content if self.use_cache?
			@server.call("wiki.putPage", path_to_pagename(path), content, message)
		end
	end

	def update
		begin
			update_command = "wiki.getRecent" + (self.media? ? "Media" : "") + "Changes";
			@server.call(update_command, @last_update).each do |page|
				path = pagename_to_path(page["name"])
				if (page['lastModified'].to_time > @last_update)
					@last_update = page['lastModified'].to_time
				end
				if self.file?(path)
					@cache.delete(page["name"]) unless self.use_cache?
					if self.read_file(path).empty?
						self.remove_from_tree(path)
					else
						self.add(path, page)
					end
				else
					self.add(path, page)
				end
			end
		rescue XMLRPC::FaultException => e
		end
		return true
	end

	def path_to_pagename(path)
		path.sub(/\.dw\Z/, "").gsub("/", ":").reverse.chop.reverse
	end

	def pagename_to_path(id)
		if self.media?
			return '/'+id.gsub(":", "/")
		else
			return '/'+id.gsub(":", "/")+'.dw'
		end
	end
end

if (File.basename($0) == File.basename(__FILE__))
	#Thread.abort_on_exception = true # for debugging...
	options = {}

	OptionParser.new do |opts|
		opts.banner = "Mount a DokuWiki over XML-RPC as filesystem under a directory.\n\nUsage: dokufs.rb [options] directory"

		opts.on("-u", "--user USER", "The username") {|options[:user]|}
		opts.on("-p", "--password PASSWORD", "The password") {|options[:password]|}
		opts.on("-s", "--server SERVER", "The server to use (default: localhost)") {|options[:host]|}
		opts.on("--path PATH", "The path to XMLRPC (default: /lib/exe/xmlrpc.php)") {|options[:path]|}
		opts.on("--[no-]ssl", "Use (no) ssl (default: use ssl)") {|options[:use_ssl]|}
		opts.on("-m", "--media", "Display media files instead of wiki pages") {|options[:media]|}
		opts.on("--update-interval INTERVAL", Integer, "The update interval in seconds") {|options[:update_interval]|}
		opts.on("-n", "--no-cache", "Don't use the cache - this will cause a significantly higher load on the server. (default: use cache)") do |c|
			options[:nocache] = !c
		end

		opts.on_tail("-h", "--help", "Show this message") do
			puts opts
			exit
		end
	end.parse!

	arg = ARGV.shift
	if ARGV.empty? && !arg.nil? && File.directory?(arg)
		root = DokuFS.new(options)
		FuseFS.set_root(root)
		FuseFS.mount_under(arg)
		updater = Thread.new do
			if (options[:update_interval])
				sleep options[:update_interval]
			else
				sleep 5*60
			end
			root.update
		end
		FuseFS.run # This doesn't return until we're unmounted.
		Thread.exit(updater)
	else
		print arg unless arg.nil?
		puts ': directory not found. Please specify an existing directory as last argument.'
		puts 'Call dokufs.rb -h for more usage information'
	end
end
