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

sub prepare_msvc_files_xml {
  my ($all, $exclude_re, $targets) = @_;
  my $last = [];
  my $depth = 2;
  my $files = "<Files>\r\n";
  for my $full (@$all) {
    my @items = split /\//, $full; # split by '/'
    $full =~ s|/|\\|g;             # replace '/' bt '\'
    #XXXXXXXXXXXXX
    shift @items;
    pop @items; # drop last one
    my $current = \@items;
    if (join(':', @$current) ne join(':', @$last)) {
      my $common = 0;
      $common++ while ($last->[$common] && $current->[$common] && $last->[$common] eq $current->[$common]);
      my $back = @$last - $common;
      if ($back > 0) {
        $files .= ("\t" x --$depth) . "</Filter>\r\n" for (1..$back);
      }
      my $fwd = [ @$current ]; splice(@$fwd, 0, $common);
      for my $i (0..scalar(@$fwd) - 1) {
        $files .= ("\t" x $depth) . "<Filter\r\n";
        $files .= ("\t" x $depth) . "\tName=\"$fwd->[$i]\"\r\n";
        $files .= ("\t" x $depth) . "\t>\r\n";
        $depth++;
      }
      $last = $current;
    }
    $files .= ("\t" x $depth) . "<File\r\n";
    $files .= ("\t" x $depth) . "\tRelativePath=\"$full\"\r\n";
    $files .= ("\t" x $depth) . "\t>\r\n";
    if ($full =~ $exclude_re) {
      for (@$targets) {
        $files .= ("\t" x $depth) . "\t<FileConfiguration\r\n";
        $files .= ("\t" x $depth) . "\t\tName=\"$_\"\r\n";
        $files .= ("\t" x $depth) . "\t\tExcludedFromBuild=\"true\"\r\n";
        $files .= ("\t" x $depth) . "\t\t>\r\n";
        $files .= ("\t" x $depth) . "\t\t<Tool\r\n";
        $files .= ("\t" x $depth) . "\t\t\tName=\"VCCLCompilerTool\"\r\n";
        $files .= ("\t" x $depth) . "\t\t\tAdditionalIncludeDirectories=\"\"\r\n";
        $files .= ("\t" x $depth) . "\t\t\tPreprocessorDefinitions=\"\"\r\n";
        $files .= ("\t" x $depth) . "\t\t/>\r\n";
        $files .= ("\t" x $depth) . "\t</FileConfiguration>\r\n";
      }
    }
    $files .= ("\t" x $depth) . "</File>\r\n";
  }
  $files .= ("\t" x --$depth) . "</Filter>\r\n" for (@$last);
  $files .= "\t</Files>";
  return $files;
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
  my $changed_count = 0;
  my @c = ();
  find({ no_chdir => 1, wanted => sub { push @c, $_ if -f $_ && $_ =~ /\.c$/ && $_ !~ /tab.c$/ } }, 'src');
  my @h = ();
  find({ no_chdir => 1, wanted => sub { push @h, $_ if -f $_ && $_ =~ /\.h$/ && $_ !~ /dh_static.h$/ } }, 'src');
  my @all = ();
  find({ no_chdir => 1, wanted => sub { push @all, $_ if -f $_ && $_ =~ /\.(c|h)$/  } }, 'src');

  my @o = sort ('src/ciphers/aes/aes_enc.o', map { $_ =~ s/\.c$/.o/; $_ } @c);
  my $var_o   = prepare_variable("OBJECTS", @o);
  (my $var_obj = $var_o) =~ s/\.o\b/.obj/sg;
  my $var_h   = prepare_variable("HEADERS", (sort @h, 'testprof/tomcrypt_test.h'));

  my $msvc_files = prepare_msvc_files_xml(\@all, qr/tab\.c$/, ['Debug|Win32', 'Release|Win32']);
  for my $m (qw/libtomcrypt_VS2008.vcproj libtomcrypt_VS2005.vcproj/) {
    my $old = read_file($m);
    my $new = $old;
    $new =~ s|<Files>.*</Files>|$msvc_files|s;
    if ($old ne $new) {
      write_file($m, $new) if $write;
      warn "changed: $m\n";
      $changed_count++;
    }
  }

  my @makefiles = qw( makefile makefile.icc makefile.shared makefile.unix makefile.mingw makefile.msvc );
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
