#!/usr/bin/perl
#
# Splits the list of files and outputs for makefile type files
# wrapped at 80 chars
#
# Tom St Denis
use strict;
use warnings;

my @a = split ' ', $ARGV[1];
my $b = $ARGV[0] . '=';
my $len = length $b;
print $b;
foreach my $obj (sort @a) {
   $len = $len + length $obj;
   $obj =~ s/\*/\$/;
   if ($len > 100) {
      print "\\\n";
      $len = length $obj;
   }
   print $obj . ' ';
}
if ($ARGV[0] eq 'HEADERS') {
   print 'testprof/tomcrypt_test.h';
}

print "\n\n";

# $Source$
# $Revision$
# $Date$
