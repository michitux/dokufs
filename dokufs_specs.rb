#!/usr/bin/ruby

require "./dokufs.rb"
require "rubygems"
require "bacon"
require "facon"

describe "a DokuFS" do
	before do
		@xmlrpc = mock("xmlrpc-client")
		XMLRPC::Client.stub!(:new3).and_return(@xmlrpc)
		@xmlrpc.stub!(:call).with("wiki.getAllPages").and_return([])
		@dokufs = DokuFS.new({})
	end
	it "should not contain any directory" do
		@dokufs.contents("/").should.be.empty
	end

	it "should allow to add and delete pages" do
		@dokufs.add("/test/page")
		@dokufs.contents("/").should.include("test")
		@dokufs.directory?("/test").should.be.true
		@dokufs.contents("/test").should.not.be.empty
		@dokufs.can_rmdir?("/test").should.be.false
		@dokufs.file?("/test/page.dw").should.be.true
		@dokufs.can_delete?("/test/page.dw").should.be.true
		@xmlrpc.should.receive(:call).with("wiki.putPage", "test:page", "", {"sum" => "deleted by DokuFS", "minor" => false}).and_return true
		@dokufs.delete("/test/page.dw")
		@dokufs.contents("/test").should.be.empty
		@dokufs.can_rmdir?("/test").should.be.true
		@dokufs.rmdir("/test")
		@dokufs.contents("/").should.be.empty
	end

	it "should use the first line as commit message" do
		@xmlrpc.should.receive(:call).with("wiki.putPage", "page", "Test", {"sum" => "A new page", "minor" => false}).and_return true
		@dokufs.write_to("/page.dw", "% A new page\nTest")
		@dokufs.contents("/").should.include("page.dw")
	end

	it "should delete a page when there is no other content but the commit message" do
		@dokufs.add("/page")
		@xmlrpc.should.receive(:call).with("wiki.putPage", "page", "", {"sum" => "D", "minor" => false}).and_return true
		@dokufs.write_to("/page.dw", "%D")
		@dokufs.contents("/").should.be.empty
	end

	it "should delete a page when there is no content" do
		@dokufs.add("/page")
		@xmlrpc.should.receive(:call).with("wiki.putPage", "page", "", {"sum" => "Deleted", "minor" => false}).and_return true
		@dokufs.write_to("/page.dw", "")
		@dokufs.contents("/").should.be.empty
	end

	it "should add newly added pages to the filetree" do
		time = Time.now.utc.to_i
		@xmlrpc.should.receive(:call).with("wiki.getRecentChanges", time).and_return([{"name" => "page"}])
		@dokufs.update
		@dokufs.file?("/page.dw").should.be.true
	end

	it "should delete pages from the filetree that were delete on the server side" do
		time = Time.now.utc.to_i
		@dokufs.add("/page")
		@xmlrpc.should.receive(:call).with("wiki.getRecentChanges", time).and_return([{"name" => "page"}])
		@xmlrpc.should.receive(:call).with("wiki.getPage", "page").and_return("")
		@dokufs.update
		@dokufs.file?("/page.dw").should.be.false
	end

	it "should not allow the creation of files with another ending than .dw" do
		@dokufs.can_write?("/page").should.be.false
		@dokufs.can_write?("/page.dwx").should.be.false
		@dokufs.can_write?("/page.dw").should.be.true
		@dokufs.can_write?("/test/test/asdf/asdf/page.dw").should.be.true
	end
end