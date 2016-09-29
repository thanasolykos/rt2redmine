# rt2redmine

Scripts to port Request Tracker (RT) tickets to Redmine issues.  Could also be used to simply export RT tickets to JSON, to be used as the basis for importing into the ticket tracker of your choice.

## Usage

1. Create `config/config.yml` (see config/config.yml.example for a template) to point scripts at your RT and Redmine instances, provide credentials, and indicate the RT queue to use as source and the Redmine project to use as destination.
2. `# perl rt2json.pl`
3. `# ruby json2redmine.rb`

The scripts are pretty good about outputting status, since they can take a while (see Performance, in Caveats below).

## Motivation

We had a few thousand tickets in an RT instance that we needed to migrate to Redmine. In order to use the native language APIs on each side, I split this into two scripts. First, a Perl script to export RT via RT::Client::REST to a directory structure that captured ticket data as JSON files and dumped attachments. Second, a Ruby script to import that data into Redmine via ActiveResource. ActiveResource had some annoying properties (not allowing me to update created_on and updated_on, nor an easy way to get at the HTTP response, a seemingly broken has_attribute?, etc...) so at times I reverted to using a simple REST client and even direct SQL connection to the backend DB.  I'm not proud of it, but it works.  If I were to do it again, I'd do it all with rest-client and forget about ActiveResource entirely.

The process attempts to attribute updates to the actual person who did each creation and update (using Redmine's X-Redmine-Switch-User functionality), but falls back to using the user you connect to the API as (e.g. Redmine Admin) if necessary.  The scripts also reset the creation and last updated dates for issue creation/updates so that they are chronologically at least semi-accurate (see Caveats below). 

## Installation

The intent is simply to clone this repo, satisfy dependencies, and run in-place. 

Perl dependencies - This project uses the following modules: RT::Client::REST, Error, MIME::Parser, JSON, Getopt::Long, File::Path, YAML, Data::Dumper

Ruby dependencies - This project uses the following gems: rest-client, JSON, active_resource, mysql, yaml

## Tests

Tests? What tests? Buyer beware.

## Caveats

Many. Some highlights:
 * There are some real quirks on both sides of this workflow.  Please read the comments in the source code for lots of info.
 * File attachments are always added as the user connecting to the API (e.g. Redmine Admin) and set to ticket creation time.
 * I ignore all RT transactions that aren't of type Create|Correspond|Comment. These are the only ones I wanted to preserve in Redmine.
 * Comments don't really exist in Redmine, so I just add them as private notes.
 * Because of the way that Redmine's permissions work, you probably need really permissive permissions on the project while doing the import (for instance, I had to set it so that all users could modify all issues). After import you can do something more restrictive (e.g. users can only see their own issues).
 * Only works if Redmine using MySQL backend because I have to do direct DB manipulation in a few places.
 * The way RT splits incoming email into a series of attachments makes this process "interesting". I had to guess at which email attachment contained the actual request content in plain text, and which were things like footers attached by mailing list software, which were HTML alternative copies of the email, etc... I got it right for my environment (where most email was sent by Gmail - we're a Google Apps campus), but I have no idea how generalized my solution would be.
 * There's a bit where I try to map RT users to Redmine users by parsing email addresses.  This works well for us because of the way email addresses and user accounts work on our campus. This may not / probably won't work for you - may require code modification.
 * The Redmine script doesn't really utilize a debug flag.  There's a line of code you can uncomment in the source if you want some add'l info, mostly about the RESTful conversation happening in the background.  The script is otherwise pretty chatty anyway.
 
Performance: It's not fast, per se.  Dumping 3,500 tickets with mostly tiny attachments took almost two hours.  Loading the same took about 20 minutes. YMMV.

## License and Copyright

This software is released under the Mozilla Public License version 2. See LICENSE.txt and NOTICE.txt for more info.
