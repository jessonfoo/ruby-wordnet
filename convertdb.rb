#!/usr/bin/ruby
# 
# Conversion script for Ruby-WordNet
# 
# == Synopsis
# 
#   ./convertdb.rb [DATADIR]
# 
# == Authors
#
# This is a port of Dan Brian's convertdb.pl in the Lingua::Wordnet
# distribution. It requires the 'strscan' library, which is in the standard
# library of Ruby 1.8.
# 
# * Michael Granger <ged@FaerieMUD.org>
# 
# == Copyright
#
# Copyright (c) 2003 The FaerieMUD Consortium. All rights reserved.
# 
# This module is free software. You may use, modify, and/or redistribute this
# software under the terms of the Perl Artistic License. (See
# http://language.perl.com/misc/Artistic.html)
# 
# == Version
#
#  $Id: convertdb.rb,v 1.3 2003/06/18 04:51:47 deveiant Exp $
# 

$LOAD_PATH.unshift ".", "lib"

require 'strscan'
require 'utils'
require 'wordnet'
require 'optparse'
require 'fileutils'

include UtilityFunctions

# Globals: Index of words => senses, StringScanner for parsing.
$senseIndex = {}
$scanner = StringScanner::new( "" )

# Source WordNet files
IndexFiles = %w[ index.noun index.verb index.adj index.adv ]
MorphFiles = {
	'adj.exc'		=> WordNet::Adjective,
	'adv.exc'		=> WordNet::Adverb,
	'noun.exc'		=> WordNet::Noun,
	'verb.exc'		=> WordNet::Verb,
	'cousin.exc'	=> '',
}
DataFiles =  {
	'data.adj'		=> WordNet::Adjective,
	'data.adv'		=> WordNet::Adverb,
	'data.noun'		=> WordNet::Noun,
	'data.verb'		=> WordNet::Verb,
}

# Struct which represents a list of files, a database, and a processor function
# for moving records from each of the files into the database.
Fileset = Struct::new( "WordNetFileset", :files, :name, :db, :processor )

# How many records to insert between commits
CommitThreshold = 2000


#####################################################################
###	M A I N   P R O G R A M
#####################################################################
def main
	$stderr.sync = $stdout.sync = true
	header "WordNet Lexicon Converter"
	errorLimit = 0

	ARGV.options {|oparser|
		oparser.banner = "Usage: #{File::basename($0)} -dv\n"

		# Debugging on/off
		oparser.on( "--debug", "-d", TrueClass, "Turn debugging on" ) {
			$DEBUG = true
			debugMsg "Turned debugging on."
		}

		# Verbose
		oparser.on( "--verbose", "-v", TrueClass, "Verbose progress messages" ) {
			$VERBOSE = true
			debugMsg "Turned verbose on."
		}

		# Error-limit
		oparser.on( "--error-limit=COUNT", "-eCOUNT", Integer,
			"Error limit -- quit after COUNT errors" ) {|arg|
			errorLimit = arg.to_i
			debugMsg "Set error limit to #{errorLimit}"
		}

		# Handle the 'help' option
		oparser.on( "--help", "-h", "Display this text." ) {
			$stderr.puts oparser
			exit!(0)
		}

		oparser.parse!
	}

	# Make sure the user knows what they're in for
	message "This program will convert WordNet data files into databases\n"\
		"used by Ruby-WordNet. This will not affect existing WordNet files,\n"\
		"but will require up to 40Mb of disk space.\n"
	exit unless /^y/i =~ promptWithDefault("Continue?", "y")

	# Open the database and check to be sure it's empty. Confirm overwrite if
	# not. Checkpoint and set up logging proc if debugging.
	if File::exists?( WordNet::Lexicon::DbFile )
		message ">>> Warning: Existing data in the Ruby-WordNet databases\n"\
			"will be overwritten.\n"
		abort( "user cancelled." ) unless 
			/^y/i =~ promptWithDefault( "Continue?", "n" )
		FileUtils::rm_rf( WordNet::Lexicon::DbFile )
	end

	# Query for the source data files
	message "Where can I find the WordNet data files?\n"
	datadir = promptWithDefault( "Data directory", "/usr/local/WordNet-1.7.1/dict" )
	abort( "Directory '#{datadir}' does not exist" ) unless File::exists?( datadir )
	abort( "'#{datadir}' is not a directory" ) unless File::directory?( datadir )
	testfile = File::join(datadir, "data.noun")
	abort( "'#{datadir}' doesn't seem to contain the necessary files.") unless
		File::exists?( testfile )

	# Open the lexicon, which creates a new database under lib/wordnet/lexicon.
	lexicon = WordNet::Lexicon::new

	# Process each fileset
	[	  # Fileset,  name,    database handle, processor
		Fileset::new( IndexFiles, "index", lexicon.indexDb, method(:parseIndexLine) ),
		Fileset::new( MorphFiles, "morph", lexicon.morphDb, method(:parseMorphLine) ),
		Fileset::new( DataFiles,  "data",  lexicon.dataDb,  method(:parseSynsetLine) ),
	].each {|set|
		message "Converting %s files...\n" % set.name
		set.db.truncate

		# Process each file in the set with the appropriate processor method and
		# insert results into the corresponding table.
		set.files.each {|file,pos|
			message "    #{file}..."

			filepath = File::join( datadir, file )
			if !File::exists?( filepath )
				message "missing: skipped\n"
				next
			end

			txn, dbh = lexicon.env.txn_begin( 0, set.db )
			entries = lineNumber = errors = 0
			File::readlines( filepath ).each {|line|
				lineNumber += 1
				next if /^\s/ =~ line

				key, value = set.processor.call( line.chomp, lineNumber, pos )
				unless key
					errors += 1
					if errorLimit.nonzero? && errors >= errorLimit
						abort( "Too many errors" )
					end
				end

				dbh[ key ] = value
				entries += 1
				print "%d%s" % [ entries, "\x08" * entries.to_s.length ]

				# Commit and start a new transaction every 1000 records
				if (entries % CommitThreshold).nonzero?
					txn.commit( BDB::TXN_NOSYNC )
					txn, dbh = lexicon.env.txn_begin( 0, set.db )
				end
			}
			message "committing..."
			txn.commit( BDB::TXN_SYNC )
			message "done (%d entries, %d errors).\n" %
				[ entries, errors ]
		}

		message "Checkpointing DB and cleaning logs..."
		lexicon.checkpoint
		lexicon.cleanLogs
		puts "done."
	}

	message "done.\n\n"
end


# Index entry patterns
IndexEntry		= /^(\S+)\s(\w)\s(\d+)\s(\d+)\s/
PointerSymbol	= /(\S{1,2})\s/
SenseCounts		= /(\d+)\s(\d+)\s/
SynsetId		= /(\d{8})\s*/

### Parse an entry from one of the index files and return the key and
### data. Returns +nil+ if any part of the netry isn't able to be parsed. The
### +pos+ argument is not used -- it's just to make the interface between all
### three processor methods the same.
def parseIndexLine( string, lineNumber, pos=nil )
	$scanner.string = string
	synsets = []
	lemma, pos, polycnt = nil, nil, nil

	raise "whole error" unless $scanner.scan( IndexEntry )
	lemma, pos, polycnt, pcnt = $scanner[1], $scanner[2], $scanner[3], $scanner[4]

	# Discard pointer symbols
	pcnt.to_i.times do |i|
		$scanner.skip( PointerSymbol ) or raise "couldn't skip pointer #{i}"
	end

	# Parse sense and tagsense counts
	$scanner.scan( SenseCounts ) or raise "couldn't parse sense counts"
	senseCount, tagSenseCount = $scanner[1], $scanner[2]

	# Find synsets
	senseCount.to_i.times do |i|
		$scanner.scan( SynsetId ) or raise "couldn't parse synset #{i}"
		synset = $scanner[1]
		synsets.push( synset )
		$senseIndex[ synset + "%" + pos + "%" + lemma ] = i.to_s
	end

	# Make the index entry and return it
	key = lemma + "%" + pos
	data = [
		polycnt,
		synsets.join(WordNet::SubDelim),
	].join( WordNet::Delim )

	return key, data
rescue => err
	message "Index entry did not parse: %s at '%s...' (line %d)\n\t%s\n" % [
		err.message,
		$scanner.rest[0,20],
		lineNumber,
		err.backtrace[0]
	]
	return nil
end


### "Parse" a morph line and return it as a key and value.
def parseMorphLine( string, lineNumber, pos )
	key, value = string.split
	return "#{key}%#{pos}", value
rescue => err
	message "Morph entry did not parse: %s for %s (pos = %s, line %d)\n\t%s\n" % [
		err.message,
		string.inspect,
		pos.inspect,
		lineNumber,
		err.backtrace[0]
	]
	return nil
end


# Synset data patterns
Synset		= /(\d+)\s(\d{2})\s(\w)\s(\w{2})\s/
SynWord		= /(\S+)\s(\w)*\s*/
SynPtrCnt	= /(\d{3})\s/
SynPtr		= /(\S{1,2})\s(\d+)\s(\w)\s(\w{4})\s/
SynFrameCnt	= /\s*(\d{2})\s/
SynFrame	= /\+\s(\d{2})\s(\w{2})\s/
SynGloss	= /\s*\|\s*(.+)?/

### Parse an entry from a data file and return the key and data. Returns +nil+
### if any part of the entry isn't able to be parsed.
def parseSynsetLine( string, lineNumber, pos )
	$scanner.string = string
	
	filenum, synsetType, gloss = nil, nil, nil
	words = []
	ptrs = []
	frames = []

	# Parse the first part of the synset
	$scanner.scan( Synset ) or raise "unable to parse synset"
	offset, filenum, synsetType, wordCount =
		$scanner[1], $scanner[2], $scanner[3], $scanner[4]

	# Parse the words
	wordCount.to_i(16).times do |i|
		$scanner.scan( SynWord ) or raise "unable to parse word #{i}"
		word, lexid = $scanner[1], $scanner[2]
		senseKey = (offset + "%" + pos + "%" + word).downcase
		if !$senseIndex.key?( senseKey )
			newKey = senseKey.sub( /\(\w+\)$/, '' )
			if !$senseIndex.key?( newKey )
				raise "Sense index does not contain sense '#{senseKey}' "\
					"(tried #{newKey}, too)."
			end
			senseKey = newKey
		end

		words.push( word + "%" + $senseIndex[senseKey].to_s )
	end
	
	# Parse pointers
	if $scanner.scan( SynPtrCnt )
		$scanner[1].to_i.times do |i|
			$scanner.scan( SynPtr ) or raise "unable to parse synptr #{i}"
			ptrs.push "%s %s%%%s %s" % [
				$scanner[1],
				$scanner[2],
				$scanner[3],
				$scanner[4],
			]
		end
	else
		raise "Couldn't parse pointer count"
	end

	# Parse frames if this synset is a verb
	if synsetType == WordNet::Verb
		if $scanner.scan( SynFrameCnt )
			$scanner[1].to_i.times do |i|
				$scanner.scan( SynFrame ) or raise "unable to parse frame #{i}"
				frames.push "#{$scanner[1]} #{$scanner[2]}"
			end
		else
			raise "Couldn't parse frame count"
		end
	end

	# Find the gloss
	if $scanner.scan( SynGloss )
		gloss = $scanner[1].strip
	end

	# This should never happen, as the gloss matches pretty much anything to
	# the end of line.
	if !$scanner.empty?
		raise "Trailing miscellaneous found at end of entry"
	end

	# Build the synset entry and return it
	synsetType = WordNet::Adjective if synsetType == WordNet::Other
	key = [ offset, synsetType ].join("%")
	data = [
		filenum,
		words.join( WordNet::SubDelim ),
		ptrs.join( WordNet::SubDelim ),
		frames.join( WordNet::SubDelim ),
		gloss,
	].join( WordNet::Delim )

	return key, data
rescue => err
	message "Synset did not parse: %s at '%s...' (pos = %s, line %d)\n\t%s\n" % [
		err.message,
		$scanner.rest[0,20],
		pos.inspect,
		lineNumber,
		err.backtrace[0]
	]
	return nil
end


# Start the program
main
