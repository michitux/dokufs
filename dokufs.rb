#!/usr/bin/ruby
# DokuFS
# A Filesystem for accessing DokuWiki (version 2008-05-05 or above)
# on your local filesystem. More information can be found on 
# http://www.content-space.de/go/dokufs
#
# Copyright (C) 2008  Michael Hamann  michael <at> content-space.de

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
# TODO: cache for pages - at the moment the performance is very poor especially when using graphical programs...

require "cgi"
require "fusefs"
require "xmlrpc/client"

class DokuFS < FuseFS::FuseDir
	DEFAULT_OPTS = {
		:use_ssl => true,
		:path => "/lib/exe/xmlrpc.php",
		:host => "localhost"
	}

	def root?
		@is_root
	end

	def initialize(user_opts = nil)
		@pages = []
		@subdirs = {}
		if ! user_opts.nil?
			opts = DEFAULT_OPTS
			opts.merge!(user_opts)
			opts[:path] += "?u=#{CGI.escape(opts[:user])}&p=#{CGI.escape(opts[:password])}" if opts[:user] && opts[:password]
			@server = XMLRPC::Client.new3(opts)
			@is_root = true
			@last_update = Time.now.utc.to_i
			@server.call("wiki.getAllPages").each do |page|
				self.add("/" + page.gsub(":", "/"))
			end
		end
	end

	def add(path)
		base, rest = split_path(path)
		case
		when base.nil?
			return false
		when rest.nil?
			@pages << base unless @pages.include?(base)
		when @subdirs.has_key?(base)
			@subdirs[base].add(rest)
		else
			(@subdirs[base] = self.class.new).add(rest)
		end
	end

	def contents(path)
		base, rest = split_path(path)
		case
		when base.nil?
			(@pages.collect { |p| p + ".dw" } + @subdirs.keys).sort.uniq
		when ! @subdirs.has_key?(base)
			nil
		when rest.nil?
			@subdirs[base].contents('/')
		else
			@subdirs[base].contents(rest)
		end
	end

	def size(path)
		puts "size called with #{path}"
		if directory?(path)
			return 4000
		else
			if file?(path)
				return read_file(path).size
			end
		end
	end

	def directory?(path)
		puts "directory? called with #{path}"
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
		puts "file? called with #{path}"
		path.sub!(/\.dw\Z/, "") if self.root?
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			@pages.include?(base)
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].file?(rest)
		end
	end

	def can_write? path
		puts "can_write? called with #{path}"
		!! (path =~ /\.dw\Z/)
	end

	# mkdir
	def can_mkdir? path
		puts "can_mkdir? called with #{path}"
		return true
	end
	def mkdir(path)
		puts "mkdir called with #{path}"
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
		puts "can_delete? called with #{path}"
		path.sub!(/\.dw\Z/, "") if self.root?
		#return false unless Process.uid == FuseFS.reader_uid
		base, rest = split_path(path)
		case
		when base.nil?
			false
		when rest.nil?
			@pages.include?(base)
		when ! @subdirs.has_key?(base)
			false
		else
			@subdirs[base].can_delete?(rest)
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
		puts "delete called with #{path}"
		path.sub!(/\.dw\Z/, "")
		@server.call("wiki.putPage", path.gsub("/", ":").reverse.chop.reverse, "", { "sum" => "deleted by DokuFS", "minor" => false })
		self.remove_from_tree(path)
	end



	# Delete an existing directory.
	def can_rmdir?(path)
		puts "can_rmdir? called with #{path}"
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
		puts "rmdir called with #{path}"
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
		puts "read_file called with #{path}"
		path.sub!(/\.dw\Z/, "")
		@server.call("wiki.getPage", path.gsub("/", ":").reverse.chop.reverse)
	end

	def write_to path, content
		puts "write_to called with #{path}"
		path.sub!(/\.dw\Z/, "")
		message = { "sum" => "", "minor" => true }
		if content[0] == "%"[0]
			content.sub!(/\A%\s?([^\n]+)\n?/m) do
				message["sum"] = $1
				""
			end
			message["minor"] = false
		end
		if content =~ /\A\s*\Z/m # when the page is empty, it is deleted
			if message["sum"].empty?
				message["sum"] = "Deleted"
				message["minor"] = false
			end
			self.remove_from_tree(path)
		else
			self.add(path)
		end
		@server.call("wiki.putPage", path.gsub("/", ":").reverse.chop.reverse, content, message)
	end

	def update
		ltime = @last_update
		@last_update = Time.now.utc.to_i
		@server.call("wiki.getRecentChanges", ltime).each do |page|
			path = "/#{page["name"].gsub(":", "/")}"
			if self.file?(path)
				self.remove_from_tree(path) if self.read_file(path).empty?
			else
				self.add(path)
			end
		end
		return true
	end
end

if (File.basename($0) == File.basename(__FILE__))
	Thread.abort_on_exception = true # for debugging...
	opts = {}
	begin
		arg = ARGV.shift
		case arg
		when "-user"
			opts[:user] = ARGV.shift
		when "-password"
			opts[:password] = ARGV.shift
		when "-server"
			opts[:host] = ARGV.shift
		when "-path"
			opts[:path] = ARGV.shift
		when "-no-ssl"
			opts[:use_ssl] = false
		else
			if ARGV.empty? && ! arg.nil? && File.directory?(arg)
				root = DokuFS.new(opts)
				FuseFS.set_root(root)
				FuseFS.mount_under(arg)
				updater = Thread.new do
					sleep 5*60
					root.update
				end
				FuseFS.run # This doesn't return until we're unmounted.
				Thread.exit(updater)
			else
				puts <<-EOF
With DokuFS you can mount a DokuWiki under a path in your filesystem

All arguments except the path where to mount are optional, defaults are ssl, localhost as server and /lib/exe/xmlrpc.php as path. No authentication is default.

Usage: dokufs.rb [-user your_username -password your_password] [-server your_server.com] [-path your/path/to/lib/exe/xmlrpc.php] [-no-ssl] path/where/to/mount/
				EOF
			end
		end
	end while arg != nil
end
