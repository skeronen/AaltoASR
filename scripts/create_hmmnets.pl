#!/usr/bin/perl

# Generates HMM networks for model training.
# Options:
#   -n         Generate numerator networks (ML training)
#   -d         Generate denumerator networks (discriminative training)
#   -o         Use original PHN transcriptions without vocabulary (only -n)
#   -e         Skip generating hmmnets if target file(s) exist
#   -k         Do not delete the word graph files (for -d)
#   -m FILE    Morph processing, given a morph vocabulary
#   -r RECIPE  Recipe file (Required)
#   -B INT     Number of batches
#   -I INT     Batch index
#   -S INT     Number of sub-batches (saves disk space in temporary path)
#   -F PATH    Path containing files L.fst, H.fst, C.fst, 
#              optional_silence.fst and end_symbol.fst
#   -T PATH    Temporary path
#   -p FLOAT   SRI lattice-tool posterior pruning threshold (for -d)
#   -l FILE    Language model (binary), required for denumerator hmmnets,
#              optional for numerator hmmnets
#   -L FLOAT   LM scale
#   -b NAME    Acoustic model base name
#   -c FILE    Feature configuration file
#   -D PATH    Aku binary directory
#   -s PATH    Aku script directory
#   -P OPTS    Options for phone_probs
#   -R SCRIPT  Recognition script (args: lna-dir, recipe; output to lna.wg).
#              Required for -d if word graphs do not exist.
#   -t FILE    Transcription in TRN format. Requires the utterance fields
#              in the recipe!
#
# NOTES: The script may have problems if the recipe contains the same
#        source file names in different directories. Uses recipe's
#        lna-field to determine file names for temporary processing.
#
#        TRN files are not handled properly, only @ marks and extra spaces
#        are filtered out. Feel free to add further transcription cleaning 
#        to load_trn function. TRN files do not currently support additional
#        silence-like rubbish models (e.g. speecon's _f and _s) that
#        work with PHN files.
#
#        If PHN files contain silence-like rubbish models (e.g. speecon's
#        _f and _s), make sure the lexicon has corresponding models for
#        them. See the example Finnish phone lexicon fin_voc.lex.
#
#        The silences are implemented as defined by the L.fst. Usually,
#        as generated by build_helper_fsts.sh/lex2fst.pl, two alternative
#        paths are generated, one for a short and one for a long silence.
#        This applies also for the PHN files, the silence definitions there
#        are NOT preserved! The other option is to use -o, in which case
#        the phonetic transcription in PHN files is used directly without
#        FST expansions. This, however, is only supported for numerator
#        networks (-n)
#
#        The script assumes that several tools, e.g. MIT fst-tools, can be
#        found through $PATH. See the program/script definitions below
#        if this is not the case.


use locale;
use strict;
use Getopt::Std;

my %opt_hash;
my %transcript_hash = ();

getopts('ndoekm:r:B:I:S:F:T:p:L:l:b:c:D:s:P:R:t:', \%opt_hash);

my $morph_voc = "";
my $recipe = "";
my $num_batches = 1;
my $batch_index = 1;
my $sub_batches = 1;
my $fst_path = ".";
my $temp_dir = ".";
my $lm_model;
my $lm_scale = 1;
my $ac_model;
my $config;
my $phone_probs_opts = "";
my $bin_dir = "";
my $script_dir = "";
my $rec_script;
my $posterior_prune = 0.000000001;
my $transcript_file;

$morph_voc = $opt_hash{'m'};
die "Recipe is required (-r)\n" if (!defined $opt_hash{'r'});
$recipe = $opt_hash{'r'};

if (defined $opt_hash{'o'}) {
  die "-o is not supported with -d" if (defined $opt_hash{'d'});
  if (defined $opt_hash{'t'}) {
    print STDERR "Warning: -t ignored with -o\n";
    delete $opt_hash{'t'};
  }
  if (defined $opt_hash{'m'}) {
    print STDERR "Warning: -m ignored with -o\n";
    delete $opt_hash{'m'};
  }
}

$num_batches = $opt_hash{'B'} if (defined $opt_hash{'B'});
$batch_index = $opt_hash{'I'} if (defined $opt_hash{'I'});
$sub_batches = $opt_hash{'S'} if (defined $opt_hash{'S'});
$fst_path = $opt_hash{'F'} if (defined $opt_hash{'F'});
$temp_dir = $opt_hash{'T'} if (defined $opt_hash{'T'});
$posterior_prune = $opt_hash{'p'} if (defined $opt_hash{'p'});
$lm_model = $opt_hash{'l'} if (defined $opt_hash{'l'});
$lm_scale = $opt_hash{'L'} if (defined $opt_hash{'L'});
$ac_model = $opt_hash{'b'} if (defined $opt_hash{'b'});
$config = $opt_hash{'c'} if (defined $opt_hash{'c'});
$bin_dir = $opt_hash{'D'} if (defined $opt_hash{'D'});
$script_dir = $opt_hash{'s'} if (defined $opt_hash{'s'});
$phone_probs_opts = $opt_hash{'P'} if (defined $opt_hash{'P'});
$rec_script = $opt_hash{'R'} if (defined $opt_hash{'R'});
$transcript_file = $opt_hash{'t'} if (defined $opt_hash{'t'});

if (length($bin_dir) > 0 && substr($bin_dir, -1, 1) ne "/") {
  $bin_dir = $bin_dir."/";
}
if (length($script_dir) > 0 && substr($script_dir, -1, 1) ne "/") {
  $script_dir = $script_dir."/";
}

if (defined $transcript_file) {
  load_trn($transcript_file);
}

#################################
# Define programs and scripts   #
#################################
my $LATTICE_RESCORE = "lattice_rescore";
my $SRI_LATTICE_TOOL = "lattice-tool";
my $MORPH_LATTICE = "morph_lattice";
my $PHN2TRANSCRIPT = "${script_dir}phn2transcript.pl";
my $PHN2FST = "${script_dir}phn2fst.pl";
my $TRANSCRIPT2FSM = "${script_dir}transcript2fsm.pl";
my $FSM2HTK = "${script_dir}fsm2htk.pl";
my $HTK2FST = "${script_dir}htk2fst.pl";

$ENV{PERL5LIB}=$script_dir if (length($script_dir) > 0);

# Define fst processing from word lattice to HMM network
my $WORDS_TO_HMMNET = "fst_optimize -A - - | fst_compose -t $fst_path/L.fst - - | fst_concatenate $fst_path/optional_silence.fst - - | fst_concatenate - $fst_path/optional_silence.fst - | ${script_dir}fill_word_out_labels.pl - | ${script_dir}fill_silence_out_labels.pl - | ${script_dir}fill_word_out_labels.pl - | fst_concatenate - $fst_path/end_mark.fst - | fst_compose -t $fst_path/C.fst - - | fst_optimize -a -A - - | fst_compose -t $fst_path/H.fst - - | ${script_dir}fill_word_out_labels.pl - | ${script_dir}finalize_hmmnet.pl | fst_optimize -a -A - -";


# Create own working directory
my $sub_temp_dir = "hmmnet_temp_${batch_index}";
my $full_temp_path = $temp_dir."/".$sub_temp_dir;
mkdir $full_temp_path;

my $num_virt_batches = $num_batches*$sub_batches;

for (my $i = 1; $i <= $sub_batches; $i++) {
  my $cur_batch = ($batch_index-1)*$sub_batches + $i;

  my $rinfo = load_recipe($recipe, $cur_batch, $num_virt_batches,
                          $full_temp_path);
  generate_word_graphs($rinfo, $full_temp_path) if ($opt_hash{'d'});

  if (!(defined $opt_hash{'o'}) &&
      ($opt_hash{'n'} || $opt_hash{'d'})) {
    generate_transcript_fsts($rinfo, $full_temp_path);
  }

  if (defined $opt_hash{'o'}) {
    numerator_hmmnets_from_phns($rinfo);
  } else {
    generate_numerator_hmmnets($rinfo, $full_temp_path) if ($opt_hash{'n'});
    generate_denumerator_hmmnets($rinfo, $full_temp_path) if ($opt_hash{'d'});

    # Delete temporary files
    for my $record (@$rinfo) {
      system("rm -f $full_temp_path/".$record->{target}.".*");
      if (!$opt_hash{'k'}) {
        # Remove word graph files
        unlink($record->{wg});
      }
    }
  }
}


sub load_trn {
  my $trn_file = shift;
  open(TRF, "< $trn_file") || die "Could not open $trn_file";
  while (<TRF>) {
    my @c;
    @c = split;
    # In TRN files, the utterance is appended with the utterance code,
    # enclosed in parentheses.
    my $key = substr($c[-1],1,-1);
    my $tr = join(' ', @c[0..($#c-1)]);

    # Clean TRN utterances
    $tr =~ s/@//g;
    $tr =~ s/\s+/ /g;

    $transcript_hash{$key} = $tr;
  }
  close(TRF);
}


sub load_recipe {
  my $recipe_file = shift(@_);
  my $batch_index = shift(@_);
  my $num_batches = shift(@_);
  my $temp_dir = shift(@_);
  my $target_lines;
  my $fh;
  my @recipe_lines;
  my @result;
  
  die "Recipe file $recipe_file does not exist!" if (!-e $recipe_file);
  open $fh, "< $recipe_file" || die "Could not open $recipe_file\n";
  @recipe_lines = <$fh>;
  close $fh;

  my $batch_remainder = 0;
  if ($num_batches <= 1) {
    $target_lines = $#recipe_lines+1;
  } else {
    $target_lines = int(($#recipe_lines+1)/$num_batches);
    $batch_remainder = ($#recipe_lines+1)%$num_batches;
  }
  my $extra_line = 1;
  if ($target_lines < 1) {
    $target_lines = 1;
    $extra_line = 0;
  }
  if ($batch_remainder == 0) {
    $extra_line = 0;
  }

  my $cur_index = 1;
  my $cur_line = 0;

  foreach my $line (@recipe_lines) {
    if ($num_batches > 1 && $cur_index < $num_batches) {
      if ($cur_line >= $target_lines + $extra_line) {
        $cur_index++;
        last if ($cur_index > $batch_index);
        $cur_line -= $target_lines + $extra_line;
        $extra_line = 0 if ($cur_index > $batch_remainder);
      }
    }
    
    if ($num_batches <= 1 || $cur_index == $batch_index) {
      my ($audio, $tr, $lna, $wgfile, $temp_target, $numfile, $denfile);
      my $utterance;
      $audio = "";
      $audio = $1 if ($line =~ /audio=(\S*)/);
      $tr = $1 if ($line =~ /transcript=(\S*)/);
      if ($line =~ /lna=(\S*)/) {
        $lna = $1;
        $wgfile = $temp_dir."/".$1.".wg";
        $temp_target = $1."_$cur_line";
      } else {
        $lna = "";
        if ($line =~ /audio=\S*\/([^\/]+)(\.[^\/]*)?\s/ ||
            $line =~ /audio=(\S*)/) {
          $wgfile = $temp_dir."/".$1.".wg";
          $temp_target = $1."_$cur_line";
        } else {
          die "No valid audio field in the recipe";
        }
      }
      if ($line =~ /hmmnet=(\S*)/) {
        $numfile = $1;
      } elsif (defined $opt_hash{'n'}) {
        die "Recipe must have hmmnet-fields with -n";
      }
      if ($line =~ /den\-hmmnet=(\S*)/) {
        $denfile = $1;
      } elsif (defined $opt_hash{'d'}) {
        die "Recipe must have den-hmmnet-fields with -d";
      }
      $utterance = $1 if ($line =~ /utterance=(\S*)/);
      if (!defined $opt_hash{'e'} || 
          (defined $opt_hash{'n'} && !(-e $numfile)) ||
          (defined $opt_hash{'d'} && !(-e $denfile))) {

        push(@result, { audio=>$audio, 
                        transcript=>$tr,
                        lna=>$lna,
                        wg=>$wgfile,
                        num=>$numfile,
                        den=>$denfile,
                        utterance=>$utterance,
                        target=>$temp_target});
      }
    }
    $cur_line++;
  }
  return \@result;
}


sub generate_word_graphs {
  my $rinfo = shift(@_);
  my $temp_dir = shift(@_);

  # my $orig_dir;
  # chomp($orig_dir = `pwd`);
  # chdir($temp_dir) || die "Could not change to directory $temp_dir";

  # Go through recipe records and find non-existent word graphs.
  # Write those records to a temporary recipe file
  my $fh;
  my $num_files = 0;
  my $temp_recipe = "$temp_dir/temp.recipe";
  open $fh, "> $temp_recipe";
  for my $record (@$rinfo) {
    if (!defined $record->{audio} || length($record->{audio}) == 0 ||
        !defined $record->{lna} || length($record->{lna}) == 0) {
      die "recipe needs audio and lna fields for generating word graphs";
    }
    if (!(-e $record->{wg}) || !check_wg_file($record->{wg})) {
      print $fh "audio=".$record->{audio}." lna=".$record->{lna}."\n";
      $num_files++;
    }
  }
  close $fh;
  if ($num_files > 0) {
    die "Acoustic model required" if (!(defined $ac_model));
    die "Feature configuration required" if (!(defined $config));
    die "Recognition script required" if (!(defined $rec_script));
    # Generate word graphs
    system("${bin_dir}phone_probs -b $ac_model -c $config -r $temp_recipe -o $temp_dir $phone_probs_opts -i 1") && die "phone_probs failed\n";

    # Generate lattices
    system("$rec_script $temp_dir $temp_recipe") && die "recognition failed\n";
    
    # Remove LNA files
    system("rm -f $temp_dir/*.lna");
  }

  # chdir($orig_dir) || die "Could not change to directory $orig_dir";
}


# A rude check that a word graph file is not corrupted. Useful e.g. when
# using Condor where a file writing may be interrupted.
sub check_wg_file {
  my $file = shift(@_);
  my $fh;
  open $fh, "< $file" || return 0;
  my $i = 0;
  my $lines = 0;
  while (<$fh>) {
    $i++;
    if (/^I=/) {
      $lines += ($i-1);
      while (<$fh>) {
        $i++;
      }
      last;
    }
    if (/^N=(\d+)/) {
      $lines += $1;
    }
    if (/\sL=(\d+)/) {
      $lines += $1;
    }
  }
  return 0 if ($i != $lines);
  return 1;
}

sub generate_transcript_fsts {
  my $rinfo = shift(@_);
  my $temp_dir = shift(@_);

  my $orig_dir;
  chomp($orig_dir = `pwd`);
  chdir($temp_dir) || die "Could not change to directory $temp_dir";

  my $fh;
  open $fh, "> temp.list";
  for my $record (@$rinfo) {
    my $tr;
    print $fh $record->{target}.".tmptr\n";
    if (defined $transcript_file) {
      die "Missing utterance field" if (!defined $record->{utterance});
      $tr = $transcript_hash{$record->{utterance}};
      die "No transcription for utterance ".$record->{utterance} if (length($tr) <= 0);
    } else {
      die "Missing transcript field" if (!defined $record->{transcript});
      my $cmd = "$PHN2TRANSCRIPT ".$record->{transcript};
      $tr = `$cmd`;
      die "Error running $cmd\n" if ($?);
      die "No transcription in file ".$record->{transcript} if (length($tr) <= 0);
    }
    $tr =~ s/^\s+//;
    $tr =~ s/\s+$//;
    if (length($morph_voc) > 0) {
      my $cur_morph_voc = $morph_voc;
      $cur_morph_voc = $orig_dir."/".$cur_morph_voc if (!(-e $cur_morph_voc));
      system("echo \"".$tr."\" | $MORPH_LATTICE $cur_morph_voc - - | $FSM2HTK > ".$record->{target}.".tmptr") && die "Transcription generation failed\n";
    } else {
      system("echo \"".$tr."\" | $TRANSCRIPT2FSM | $FSM2HTK > ".$record->{target}.".tmptr") && die "Transcription generation failed\n";
    }
  }
  close $fh;

  my $temp_out_dir = ".";
  if (defined $lm_model) {
    my $cur_lm_model = $lm_model;
    $cur_lm_model = $orig_dir."/".$cur_lm_model if (!(-e $cur_lm_model));
    $temp_out_dir = "out";
    die "Temporary output directory already exists!" if (-e $temp_out_dir);
    mkdir($temp_out_dir);
    system("$LATTICE_RESCORE -l $cur_lm_model -I temp.list -O $temp_out_dir") && die "Transcription lattice rescoring failed\n";
  }

  for my $record (@$rinfo) {
    system("$HTK2FST $temp_out_dir/".$record->{target}.".tmptr | fst_nbest -t -1000 -n 1 -p - - | perl -npe \'s/<\\/s>/,/g;\' | fst_optimize -A - ".$record->{target}.".fst") && die "Transcription FST generation failed\n";
  }

  # Remove temporary files
  system("rm -rf $temp_out_dir") if (defined $lm_model);
  system("rm temp.list");

  chdir($orig_dir) || die "Could not change to directory $orig_dir";
}


sub numerator_hmmnets_from_phns {
  my $rinfo = shift(@_);

  die "Acoustic model required" if (!(defined $ac_model));

  for my $record (@$rinfo) {
    print STDERR "".$record->{transcript}."\n";
    if (system("$PHN2FST $ac_model.ph ".$record->{transcript}." > ".$record->{num})) {
      print STDERR "Reading from ".$record->{transcript}.", writing to ".$record->{num}."\n";
      die "Error generating HMM networks directly from PHNs";
    }
  }
}


sub generate_numerator_hmmnets {
  my $rinfo = shift(@_);
  my $temp_dir = shift(@_);

  for my $record (@$rinfo) {
    if (system("fst_clear_weights $temp_dir/".$record->{target}.".fst - | $WORDS_TO_HMMNET > ".$record->{num})) {
      print STDERR "Transcription FST operations failed for ".$record->{num}."\n";
      print STDERR "(maybe OOV words in transcription?)\n";
      die;
    }
  }
}


sub generate_denumerator_hmmnets {
  my $rinfo = shift(@_);
  my $temp_dir = shift(@_);

  for my $record (@$rinfo) {
    system("fst_project e e $temp_dir/".$record->{target}.".fst - | ${script_dir}negate_fst_weights.pl | fst_optimize -A - $temp_dir/".$record->{target}.".weight.fst") && die "system error $7\n";

    system("$LATTICE_RESCORE -l $lm_model -i ".$record->{wg}." -o - | $SRI_LATTICE_TOOL -posterior-prune $posterior_prune -read-htk -in-lattice - -write-htk -out-lattice - -htk-lmscale $lm_scale -htk-acscale 1 -posterior-scale $lm_scale | $HTK2FST | fst_union - $temp_dir/".$record->{target}.".fst - | fst_concatenate $temp_dir/".$record->{target}.".weight.fst - - | $WORDS_TO_HMMNET > ".$record->{den}) && die "Lattice FST operations failed\n";
  }
}
