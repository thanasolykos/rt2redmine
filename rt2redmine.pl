use Error qw(:try);
use RT::Client::REST;
use MIME::Parser;
use Data::Dumper;
use JSON;

# if/when we get non-Shib access, we can take this approach
# test server
#my $rt = RT::Client::REST->new(server => 'http://192.168.56.101');
# real server
my $rt = RT::Client::REST->new(server => 'https://rt.cla.umn.edu');

# json coder
my $json = new JSON->ascii->pretty;

try {
  # test server login
  #$rt->login(username => 'root', password => 'password');
  # real server login
  $rt->login(username => 'mpcexport', password => 'jw8wfJvi8PxauZhx');
} catch Exception::Class::Base with {
  die "Can't login: ", shift->message;
};

my @ids;
try {
  #$t = $rt->show(type => 'ticket', id => 1);
  @ids = $rt->search(type => "ticket", query => "Queue = 'mpc-admin-request' AND Id > 110000");
} catch RT::Client::REST::UnauthorizedActionException with {
  print "You are not authorized to view ticket\n";
} catch RT::Client::REST::Exception with {
  # something went wrong.
};

my $numtickets = scalar(@ids);
my $processedtickets = 0;

print "Starting loop to create JSON representations of tickets and save associated attachments.\n";
foreach $tid (sort {$a <=> $b} @ids) {
  print "Processing $tid...";
  my $ticket = $rt->show(type => 'ticket', id => $tid);
  # get history
  my @trans_ids = $rt->get_transaction_ids(parent_id => $tid);
  foreach my $trid (@trans_ids) {
    my $trans = $rt->get_transaction(parent_id => $tid, id => $trid);
    # we only care about the Correspondence and Comments.  Other transaction types make no sense for Redmine.
    if ($trans->{Type} =~ /Correspond|Comment/) {
      push @{$ticket->{Transactions}}, $trans;
    }
  }
  # attachments
  my @att_ids = $rt->get_attachment_ids(id => $tid);
  if (@att_ids) {
    push @{$ticket->{Attachment_IDs}}, @att_ids;
  }
  
  # write out ticket data in JSON
  mkdir "tickets/$tid" if ! -d "tickets/$tid";
  open OUTJSON, ">", "tickets/$tid/$tid.json" or die "Can't open JSON file for output.\n";
  print OUTJSON $json->pretty->encode($ticket);
  close OUTJSON;
  
  # process attachments for this ticket, if any
  foreach $att_id (@att_ids) {
    # docs suggested we set undecoded to a TRUE value for binary data, but my experiements show the opposite.
    # if you set undecoded to TRUE, you get Base64-encoded data out, which garbles the binary.
    my $att = $rt->get_attachment(id => $att_id, parent_id => $tid, undecoded => 0);
    # a lot of "attachments" are really just email signatures.  These do not have filenames.
    if ($att->{Filename} eq '') { next }
    # we have a real attachment, write it out
    mkdir "tickets/$tid/attachments" if ! -d "tickets/$tid/attachments";
    my $filename = "tickets/$tid/attachments/" . $att->{Filename};
    open OUT, ">", $filename or die "Can't open $filename for writing.\n";
    print OUT $att->{Content};
    close OUT; 
    # verify length equivalent - this is a sanity check.  
    ($length) = $att->{Headers} =~ /Content-Length: (\d+)/;
    # some files were off by 1 but were still open-able.  
    if (abs($length - (-s $filename)) > 1) {
      die "File lengths do not match! (ticket $tid, attachment $att_id, filename $filename, header length $length, fs length " . (-s $filename) . ")\n";
    }
  }
  print "done (" . ++$processedtickets . " of $numtickets)\n";
}
print "Finished loop to create JSON representations of tickets and save associated attachments.\n"


 
#   my $historystr = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/ticket/$tid/history?format=l"`;
#   $historystr = strip_header(\$historystr);
#   my @transactions = parse_history(\$historystr);
#   print Dumper(\@transactions);

# in the meantime, we'll do it with webisoget, clunky but works

# tickets in admin queue
# my $admin_tickets_REST = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/search/ticket?query=Queue=%27mpc-admin-request%27"`;
# my @lines = split /\n/, $admin_tickets_REST;
# my @ticket_ids;
# foreach $line (@lines) {
#   my ($id) = $line =~ /^(\d+)\:/;
#   push @ticket_ids, $id if $id;
# }
# print "Retrieved ticket IDs for mpc-admin-request queue.\n";
#
# # loop over tickets, getting properties and transaction history
# foreach $tid (sort {$a <=> $b} @ticket_ids) {
#   print "Processing $tid...\n";
#   my $propstr = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/ticket/$tid/show"`;
#   $propstr = strip_header(\$propstr);
#   my $props = parse_props(\$propstr);
#   my $historystr = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/ticket/$tid/history?format=l"`;
#   $historystr = strip_header(\$historystr);
#   my @transactions = parse_history(\$historystr);
#   print Dumper(\@transactions);
# }
#
# sub strip_header {
#   my $strref = shift;
#   $str = $$strref;
#   $str =~ s/^.*?\n//;
#   $str =~ s/^.*?\n//;
#   return $str;
# }
#
# sub parse_props {
#   my $props = shift;
#   open my $fh, '<', $props;
#   my %prophash;
#   while (<$fh>) {
#     if (($field, $value) = /(.*?)\:\s+(.*?)\n/) {
#       $prophash{$field} = $value;
#     }
#   }
#   close $fh;
#   return \$prophash;
# }
#
# sub parse_history {
#   my $history = shift;
#   my @records = split /^--$/m, $$history;
#   my $parser = new MIME::Parser;
#   foreach my $rec (@records) {
#     my $entity = $parser->parse_data(\$rec);
#     print Dumper($entity);
#   }
# }
