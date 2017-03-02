#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use File::Find 'find';
use File::Basename 'basename';
use File::Glob 'bsd_glob';

sub read_file {
  my $f = shift;
  open my $fh, "<", $f or die "FATAL: read_rawfile() cannot open file '$f': $!";
  binmode $fh;
  return do { local $/; <$fh> };
}

sub write_file {
  my ($f, $data) = @_;
  die "FATAL: write_file() no data" unless defined $data;
  open my $fh, ">", $f or die "FATAL: write_file() cannot open file '$f': $!";
  binmode $fh;
  print $fh $data or die "FATAL: write_file() cannot write to '$f': $!";
  close $fh or die "FATAL: write_file() cannot close '$f': $!";
  return;
}

sub check_source {
  my @all_files = (bsd_glob("makefile*"), bsd_glob("*.sh"), bsd_glob("*.pl"));
  find({ wanted=>sub { push @all_files, $_ if -f $_ }, no_chdir=>1 }, qw/src testprof demos/);

  my $fails = 0;
  for my $file (sort @all_files) {
    next unless $file =~ /\.(c|h|pl|py|sh)$/ || basename($file) =~ /^makefile/i;
    my $troubles = {};
    my $lineno = 1;
    my $content = read_file($file);
    push @{$troubles->{crlf_line_end}}, '?' if $content =~ /\r/;
    for my $l (split /\n/, $content) {
      push @{$troubles->{merge_conflict}}, $lineno if $l =~ /^(<<<<<<<|=======|>>>>>>>)([^<=>]|$)/;
      push @{$troubles->{trailing_space}}, $lineno if $l =~ / $/;
      push @{$troubles->{tab}}, $lineno            if $l =~ /\t/ && basename($file) !~ /^makefile/i;
      push @{$troubles->{non_ascii_char}}, $lineno if $l =~ /[^[:ascii:]]/;
      $lineno++;
    }
    for my $k (sort keys %$troubles) {
      warn "[$k] $file line:" . join(",", @{$troubles->{$k}}) . "\n";
      $fails++;
    }
  }

  warn( $fails > 0 ? "check-source:    FAIL $fails\n" : "check-source:    PASS\n" );
  return $fails;
}

sub prepare_variable {
  my ($varname, @list) = @_;
  my $output = "$varname=";
  my $len = length($output);
  foreach my $obj (sort @list) {
    $len = $len + length $obj;
    $obj =~ s/\*/\$/;
    if ($len > 100) {
      $output .= "\\\n";
      $len = length $obj;
    }
    $output .= $obj . ' ';
  }
  $output =~ s/ $//;
  return $output;
}

sub patch_makefile {
  my ($in_ref, $out_ref, $data) = @_;
  open(my $src, '<', $in_ref);
  open(my $dst, '>', $out_ref);
  my $l = 0;
  while (<$src>) {
    if ($_ =~ /START_INS/) {
      print {$dst} $_;
      $l = 1;
      print {$dst} $data;
    } elsif ($_ =~ /END_INS/) {
      print {$dst} $_;
      $l = 0;
    } elsif ($l == 0) {
      print {$dst} $_;
    }
  }
  close $dst;
  close $src;
}

sub process_makefiles {
  my $write = shift;
  my @c = ();
  find({ no_chdir => 1, wanted => sub { push @c, $_ if -f $_ && $_ =~ /\.c$/ && $_ !~ /tab.c$/ } }, 'src');
  my @h = ();
  find({ no_chdir => 1, wanted => sub { push @h, $_ if -f $_ && $_ =~ /\.h$/ && $_ !~ /dh_static.h$/ } }, 'src');

  my @o = sort ('src/ciphers/aes/aes_enc.o', map { $_ =~ s/\.c$/.o/; $_ } @c);
  my $var_o   = prepare_variable("OBJECTS", @o);
  (my $var_obj = $var_o) =~ s/\.o\b/.obj/sg;
  my $var_h   = prepare_variable("HEADERS", (sort @h, 'testprof/tomcrypt_test.h'));

  my @makefiles = qw( makefile makefile.icc makefile.shared makefile.unix makefile.mingw makefile.msvc );
  my $changed_count = 0;
  for my $m (@makefiles) {
    my $old = read_file($m);
    my $new;
    if ($m eq 'makefile.msvc') {
      patch_makefile(\$old, \$new, "$var_obj\n\n$var_h\n\n");
    }
    else {
      patch_makefile(\$old, \$new, "$var_o\n\n$var_h\n\n");
    }
    if ($old ne $new) {
      write_file($m, $new) if $write;
      warn "changed: $m\n";
      $changed_count++;
    }
  }
  if ($write) {
    return 0; # no failures
  }
  else {
    warn( $changed_count > 0 ? "check-makefiles: FAIL $changed_count\n" : "check-makefiles: PASS\n" );
    return $changed_count;
  }
}

sub die_usage {
  die <<"MARKER";
  usage: $0 --check-source
         $0 --check-makefiles
         $0 --update-makefiles
MARKER
}

GetOptions( "check-source"     => \my $check_source,
            "check-makefiles"  => \my $check_makefiles,
            "update-makefiles" => \my $update_makefiles,
            "help"             => \my $help
          ) or die_usage;

my $failure;
$failure ||= check_source()       if $check_source;
$failure ||= process_makefiles(0) if $check_makefiles;
$failure ||= process_makefiles(1) if $update_makefiles;

die_usage unless defined $failure;
exit $failure ? 1 : 0;