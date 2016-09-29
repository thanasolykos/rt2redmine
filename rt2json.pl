# This file is part of the Minnesota Population Center's rt2redmine project.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/mnpopcenter/rt2redmine

use strict;

use Error qw(:try);
use RT::Client::REST;
use MIME::Parser;
use Data::Dumper;
use JSON;
use Getopt::Long;
use File::Path qw/make_path/;
use YAML qw/LoadFile/;

# load config
open my $fh, '<', 'config/config.yml' 
  or die "can't open config file: $!";
my $config = (LoadFile($fh))->{'rt2json'};

# options handling

my $start = $config->{'start'};
my $debug = $config->{'debug'};
GetOptions ("start=i" => \$start,    # numeric
            "debug"  => \$debug)   # flag
or die("Error in command line arguments\n");

# create REST client object
my $rt = RT::Client::REST->new(server => $config->{'server'});

# json coder
my $json = new JSON->ascii->pretty;

try {
  # server login
  $rt->login(username => $config->{'username'}, password => $config->{'password'});
} catch Exception::Class::Base with {
  die "Can't login: ", shift->message;
};

my @ids;
try {
  @ids = $rt->search(type => "ticket", query => "Queue = '" . $config->{'queue'} . "' AND Id >= $start");
} catch RT::Client::REST::UnauthorizedActionException with {
  print "You are not authorized to view ticket\n";
} catch RT::Client::REST::Exception with {
  # something went wrong.
};

my $numtickets = scalar(@ids);
my $processedtickets = 0;

print "Starting loop to create JSON representations of tickets and save associated attachments.\n";
foreach my $tid (sort {$a <=> $b} @ids) {
  my $create_trans = undef;
  print "Processing RT ticket $tid...\n";
  my $ticket = $rt->show(type => 'ticket', id => $tid);
  
  # get history
  my @trans_ids = $rt->get_transaction_ids(parent_id => $tid);
  foreach my $trid (@trans_ids) {
    my $trans = $rt->get_transaction(parent_id => $tid, id => $trid);

    # we only care about the Create, Correspond and Comment transactions.  
    # Other transaction types make no sense for Redmine (at least for ours).
    if ($trans->{Type} =~ /Create|Correspond|Comment/) {
      push @{$ticket->{Transactions}}, $trans;
      # additionally, if this is the create transaction, grab ID so we can use later
      if ($trans->{Type} =~ /Create/) {
        $create_trans = $trid;
      }
    }
  }
  
  # attachments
  
  # Ok, we have to process attachments first, because of the way RT processes incoming 
  # emails / returns history in its API.  The content of the ticket request in the email is
  # stored as a set of attachments (not just one becaue the email will be multipart/mixed, e.g. Gmail
  # will send both an HTML and a plain text version, etc...)  I haven't looked closely at the RT code
  # to determine how it decides which attachment to render in the web UI, but the net result from the API
  # is that when you get the transaction history, the Content of the transaction object will usually not
  # be the meaningful content you want (in my case, it was an email footer that was tacked on by mailing list
  # software before the email hit RT).  To get to the valuable content, you have to process the attachments
  # and extract the stuff you want.  Since I am migrating to Redmine, I want that initial content to be in
  # the issue description.  RT doesn't have that concept of a ticket description - the request is just the first
  # thing in the ticket history.  So we have to fudge a bit.
  
  my @att_ids = $rt->get_attachment_ids(id => $tid);
  
  if (@att_ids) {
    push @{$ticket->{Attachment_IDs}}, @att_ids;
  }
  
  # process attachments for this ticket, if any
  # this means both "real" attachments, as in someone put a file on the ticket, and incoming emails, which get
  # parsed into a series of attachments, and are not always reflected in the ticket history from the API like 
  # you'd expect.  All this business about parents refers to the way that RT breaks apart an email into various attachments that have parent-child relationships.
  my $current_parent;
  my $alt_parent; 
  foreach my $att_id (sort {$a <=> $b} @att_ids) {
    # docs suggested we set undecoded to a TRUE value for binary data, but my experiements show the opposite.
    # if you set undecoded to TRUE, you get Base64-encoded data out, which garbles the binary.
    my $att = $rt->get_attachment(id => $att_id, parent_id => $tid, undecoded => 0);
    print "Processing attachment $att_id ($att->{ContentType}, Parent: $att->{Parent})\n";
       
    # basic pattern is that an incoming email will have 1 or more 0b attachments as parents (multipart/mixed, or multipart/alternative content types, I believe) and then those will have multiple children (RT attachments have the concept of a parent attachment we can use to determine children) - basically, we MAY want to preserve text/plain children.  Some text/plain children are email footers - I believe at one time our incoming requests were routed through mailing list software before being forwarded to RT, and the mailing list added a footer - these can be distinguished from other text/plain children by looking at the Headers... for the footer attachments, the Headers had MIME information, whereas for the "real" content they did not seem to have that.
         
    if ($att->{ContentType} eq 'multipart/mixed') {
      # we assume this is a parent attachment for an incoming email
      # don't need to do anything but remember the ID
      $current_parent = $att_id;
      print "  Skipping - parent attachment. Set current_parent to $current_parent.\n";
      next;
    } elsif ($current_parent && $att->{Parent} == $current_parent && $att->{ContentType} eq 'multipart/alternative') {
      $alt_parent = $att_id;
      print "  Skipping - multipart/alternative child.  Set alt_parent to $alt_parent.\n";
      next;
    } elsif ($current_parent && ($att->{Parent} == $current_parent || $att->{Parent} == $alt_parent) && $att->{ContentType} eq 'text/html') {
      print "  Skipping - alternative text/html child.\n";
      next;
    } elsif ($current_parent && ($att->{Parent} == $current_parent || $att->{Parent} == $alt_parent) && $att->{ContentType} eq 'text/plain') {
      if ($att->{Headers} =~ /^MIME/) {
        # this is likely a mailing list footer attachment; skip
        print "  Skipping - extraneous footer.\n";
        next;
      } elsif ($att->{Transaction} == $create_trans) {
        # This is the email content of the initial email that created the ticket.  We'll want to use
        # it for the Redmine description, so tack it onto the ticket object itself.
        print "  Special - text/plain child as part of the Create transaction.  Adding as ticket description.\n"; 
        $ticket->{Description} = $att->{Content};
        next;
      } else {
        # This is a text/plain update not done at creation time.  Could be a plain text file? 
        print "  Continuing - Unknown text/plain child.\n" 
      }
    }
    
    # if you've gotten this far, I -think- the right thing to do is to only treat it as an attachment if a filename is present.
    if (! $att->{Filename}) {
      print "  Skipping - No filename.\n";
      next;
    }
    
    # we have a real attachment, write it out
      print "  Yay! Real attachment. Saving.\n";    
    make_path($config->{'tickets_directory'} . "$tid/attachments") if ! -d $config->{'tickets_directory'} . "$tid/attachments";
    my $filename = $config->{'tickets_directory'} . "$tid/attachments/" . $att->{Filename};
    open OUT, ">", $filename or die "Can't open $filename for writing.\n";
    print OUT $att->{Content};
    close OUT;
    open OUT, ">", $config->{'tickets_directory'} . "$tid/att" . $att->{id} .  ".json" or die "Can't open $config->{'tickets_directory'}$tid/att" . $att->{id} .  ".json for writing.\n";
    print OUT $json->pretty->encode($att);
    close OUT;
    $debug && print Dumper($att);
    
    # verify length equivalent - this is a sanity check. 
    # I'm not sure this is valid, though.
    # sometimes there is no length in the headers - in this case we write out the attachment and hope for the best. 
    my ($length) = $att->{Headers} =~ /Content-Length: (\d+)/;
    # some files were off by 1 or 2 but were still open-able.  
    if ($length && (abs($length - (-s $filename)) > 2)) {
      warn "File lengths do not match! (ticket $tid, attachment $att_id, filename $filename, header length $length, fs length " . (-s $filename) . ")\n";
    }
  }
  
  # write out ticket data in JSON
  mkdir $config->{'tickets_directory'} . $tid if ! -d $config->{'tickets_directory'} . $tid;
  open OUTJSON, ">", $config->{'tickets_directory'} . "$tid/$tid.json" or die "Can't open JSON file for output.\n";
  print OUTJSON $json->pretty->encode($ticket);
  close OUTJSON;
  $debug && print $json->pretty->encode($ticket);
  
  print "done (" . ++$processedtickets . " of $numtickets)\n";
}
print "Finished loop to create JSON representations of tickets and save associated attachments.\n"
