# -*-cperl-*-
package Text::NCleaner::NGram;

use warnings;
use strict;

=head1 NAME

Text::NCleaner::NGram - Simple character-level n-gram language model

=cut

## attempt to compile the Inline::C implementation for (much) faster processing
our $HAVE_NGRAMC; # this indicates whether the fast implementation can be used
BEGIN {
  $HAVE_NGRAMC = eval 'use Text::NCleaner::NGramC; 1';
}

use Carp;
use FileHandle;
use Data::Dumper;
use List::Util qw(sum);

our $DEFAULT_Q = 0.6; # default interpolation factor for geometrically scaled interpolation

=head1 SYNOPSIS

This module implements simple character-level n-gram language models using
geometric interpolation for the history and add-one smoothing for unigrams.
It is intended for byte strings that consist mostly of ASCII characters and
will ignore any characters outside this range. The module will not work
properly with strings treated as Unicode data by the Perl interpreter; these
should be converted to UTF-8 or a suitable ISO-8859 encoding first (using the
B<Encode> module).

    use Text::NCleaner::NGram;

B<TODO: add brief usage example>

=head1 METHODS

=over 4

=item I<$model> = B<new> Text::NCleaner::NGram I<$n>;

Initialise new, untrained n-gram model of order I<$n> (history size is I<$n>-1).
Returns object of class B<Text::NCleaner::NGram>.

=item I<$model> = B<new> Text::NCleaner::NGram I<$filename>;

Load pre-trained n-gram model from file I<$filename> (must have been
serialised with B<save> method).

=cut

sub new ( $$ ) {
  croak "Usage: \$model = new Text::NCleaner::NGram [ \$n | \$filename ];"
    unless @_ == 2;
  my $class = shift;
  my $n_or_filename = shift;

  if ($n_or_filename =~ /^[0-9]+$/) {
    my $n = $n_or_filename + 0;
    my $self = bless {}, $class;
    $self->{N} = $n;		  # highest-order n-grams stored in the model
    $self->{USE_N} = $n;          # default n-gram order to use for estimation of string probabilities
    $self->{CP} = [ map { {} } 0 .. $n ]; # hashes for conditional k-gram probabilities (k = 1 .. n)
    $self->{Q} = $DEFAULT_Q;      # interpolation factor for geometrically scaled interpolation
    $self->{NORMALIZE} = 1;       # default normalization mode: reduce to ASCII characters 32 - 126
    $self->{DEBUG} = 0;           # debug mode status (0 = none, 1 = normal, 2 = verbose, 3 = overkill)
    $self->{TRAINED} = 0;         # model needs to be trained before it can be used
    return $self;
  }
  else {
    my $filename = $n_or_filename;
    my $self = do $filename;
    croak "Format error in n-gram model file '$filename': $@" if $@;
    croak "I/O error while loading n-gram model from file '$filename': $!" unless defined $self;
    croak "File '$filename' is not an n-gram model."
      unless ref($self) and ref($self) eq "Text::NCleaner::NGram";
    return $self;
  }
}

=item I<$model>->B<save>(I<$filename>);

Save trained n-gram model to portable disk file. The serialised file is Perl
code (generated by B<Data::Dumper>) which can be executed to recreate the
B<Text::NCleaner::NGram> object.

=cut

sub save ( $$ ) {
  croak "Usage: \$model->save(\$filename);"
    unless @_ == 2;
  my $self = shift;
  my $filename = shift;
  croak "This n-gram model hasn't been trained yet, no point in saving to file '$filename'."
    unless $self->{TRAINED};
  $self->debug(0);     # don't save model with debugging activated by default!
  my $serializer = new Data::Dumper [$self], ["NCLEANER_NGRAM_MODEL"];
  $serializer->Indent(1);
  my $fh = new FileHandle "> $filename"
    or croak "Can't write file '$filename': $!";
  print $fh $serializer->Dump
    or croak "I/O error while saving n-gram model to file '$filename': $!";
   $fh->close
     or croak "I/O error while saving n-gram model to file '$filename': $!";
}

=item I<$model>->B<debug>(I<$level>);

Enable / disable debugging messages.  Debugging level 1 performs additional
consistency checks and prints some diagnostic messages.  Debugging level 2
prints detailed information.

=item I<$model>->B<set_q>(I<$q>);

Set interpolation factor I<$q> of the n-gram model, which must be in the range
I<(0,1)>.  Values close to 1 correspond to strong smoothing (all history sizes
have equal weight) while values very close to 0 disable smoothing.

=item I<$model>->B<set_n>(I<$n>);

Set order of n-gram model to use, corresponding to a history size of I<$n>-1 characters.
I<$n> may not be larger than the order the model has been initialised and trained with.

=item I<$model>->B<normalize>(I<$mode>);

Set text normalisation mode to one of the following values, which specify
increasingly heavy normalisation.

    0 = minimal normalisation (only whitespace and control characters)
    1 = map all high-bit characters (outside ASCII range) to "~"
    2 = map ASCII letters to "a" for vowels and "t" for consonants, digits to "0"
    3 = non-lexical model, maps all ASCII letters to "a" and all digits to "0"

=cut

sub debug ( $$ ) {
  my $self = shift;
  my $status = shift;
  $self->{DEBUG} = $status;
}

sub set_q ( $$ ) {
  croak "Usage: \$model->set_q(\$q);"
    unless @_ == 2;
  my $self = shift;
  my $q = shift;
  croak "q-factor for NGram model must be in range (0,1), q=$q is not allowed."
    unless 0 < $q and $q < 1;
  $self->{Q} = $q;
}

sub set_n ( $$ ) {
  croak "Usage: \$model->set_n(\$n);"
    unless @_ == 2;
  my $self = shift;
  my $n = int(shift);
  my $max_n = $self->{N};
  croak "Invalid default n-gram size n=$n (must be in range 1 .. $max_n)"
    unless 1 <= $n and $n <= $max_n;
  $self->{USE_N} = $n;
}

sub normalize ( $$ ) {
  croak "Usage: \$model->normalize(\$mode); # valid modes are 0 .. 3"
   unless @_ == 2;
  my $self = shift;
  my $mode = int(shift);
  croak "Unknown normalization mode '$mode' (valid modes are 0 .. 3)"
    unless $mode >= 0 and $mode <= 3;
  croak "Normalization mode must be set BEFORE training the model!"
    if $self->{TRAINED};
  $self->{NORMALIZE} = $mode;
}

=item I<$model>->B<train>(I<$text>);

=item I<$model>->B<train>(I<$text>, I<$diff_text>);

Train n-gram model on I<$text>.  The second form performs B<differential
training>, where n-gram counts for I<$diff_text> are subtracted from those of
I<$text>.  If I<$diff_text> is a subset of I<$text>, this feature approximates
training on the difference of the two texts (which may be difficult to compute
in some cases).

=cut

sub train ( $$;$ ) {
  croak "Usage: \$model->train(\$text [, \$diff_text]);"
    unless @_ == 2 or @_ == 3;
  my ($self, $text, $diff_text) = @_;
  $diff_text = "" unless $diff_text;
  my $debug = $self->{DEBUG};

  $text = $self->_normalise_text($text);
  $diff_text = $self->_normalise_text($diff_text);

  my $n_text = length($text); 	# length of text / diff text in characters
  my $n_diff = length($diff_text);
  my $n_train = $n_text - $n_diff;

  print "Training on $n_text - $n_diff = $n_train characters.\n"
    if $debug > 0;

  ## obtain n-gram counts for training data
  foreach my $n (1 .. $self->{N}) {
    print " - $n-grams\n"
      if $debug > 0;
    my $CP = $self->{CP}->[$n];
    _count_ngrams($n, $text, 1, $CP);
    _count_ngrams($n, $diff_text, -1, $CP)
      if $n_diff > 0;
    foreach my $ngram (keys %$CP) {
      delete $CP->{$ngram} if $CP->{$ngram} <= 0; # delete 0 or (inconsistent) negative entries
    }
  }

  ## convert absolute frequencies to conditional probabilities
  foreach my $n (reverse 2 .. $self->{N}) {
    my $CP_n = $self->{CP}->[$n];
    my $CP_n_m1 = $self->{CP}->[$n - 1];
    foreach my $ngram (keys %$CP_n) {
      my $f = $CP_n->{$ngram};
      my $ngram_m1 = substr($ngram, 0, $n-1);
      my $fC = $CP_n_m1->{$ngram_m1} || 0;
      if ($f > $fC) {
	if ($n_diff > 0) {
	  print STDERR "WARNING: n-gram counts are inconsistent: f($ngram) = $f > f($ngram_m1) = $fC\n"
	    if $debug > 2;
	  $fC = $f; # handle inconsistencies gracefully for differential training
	}
	else {
	  print STDERR "ERROR: n-gram counts are inconsistent: f($ngram) = $f > f($ngram_m1) = $fC\n";
	  die "Training aborted. Please contact the developer.\n";
	}
      }
      $CP_n->{$ngram} = $f / $fC;
    }
  }

  ## convert to relative frequency = probability for unigrams
  my $CP_1 = $self->{CP}->[1];
  my $all_chars = join("", map {chr($_)} 32 .. 255); # first construct a list of all normalised characters
  my %norm_chars = map { $_ => 1 } split //, $self->_normalise_text($all_chars); # use hash to remove duplicates
  foreach my $c (keys %norm_chars) { 
    $CP_1->{$c}++;	       # perform simple add-one smoothing for unigrams
  }
  my $unigram_count = sum(values %$CP_1);
  foreach my $v (values %$CP_1) {
    $v /= $unigram_count; 	# should update value within hash structure
  }

  ## consistency check: make sure that conditional probabilities always add up to 1
  foreach my $n (2 .. $self->{N}) {
    my $CP_n = $self->{CP}->[$n];
    my %sum_P = ();
    foreach my $ngram (keys %$CP_n) {
      $sum_P{ substr($ngram, 0, $n-1) } += $CP_n->{$ngram};
    }
    my @inconsistencies = grep { abs($sum_P{$_} - 1.0) > 1e-14 } keys %sum_P;
    if (@inconsistencies) {
      if ($n_diff == 0 or $debug > 1) {
	print STDERR "ERROR: conditional probabilities are inconsistent for the following $n-grams:\n";
	  foreach my $ngram_m1 (@inconsistencies) {
	    print STDERR "\tsum Pr(.|$ngram_m1) = $sum_P{$ngram_m1} != 1.0\n";
	  }
      }
      die "Training aborted. Please contact the developer.\n"
	unless $n_diff > 0; # allow for deficient language model with differential training
    }
  }

  $self->{TRAINED} = 1;
}

=item I<$bits_per_char> = I<$model>->B<cross_entropy>(I<$text> [, I<$n>]);

Estimate cross-entropy, i.e. the average surprise per character measured in bits,
for I<$model> on the string I<$text>.  The optional argument I<$n> specifies the 
order of the n-gram model to use (up to the order used in training).

=item I<$log_p> = I<$model>->B<log_prob>(I<$text> [, I<$n>]);

Calculate the base-2 logarithm of the probability of I<$text> according to
I<$model>.  The optional argument I<$n> specifies the order of the n-gram
model to use (up to the order used in training).

=cut

sub cross_entropy ( $$; $ ) {
  croak "Usage: \$bits_per_char = \$model->cross_entropy(\$text [, \$n]);"
    unless @_ == 2 or @_ == 3;
  my $self = shift;
  my ($log_p, $len) = $self->log_prob(@_);
  return -$log_p / $len;
}

## compute base-2 logarithm of estimated probability of string $text
sub log_prob ( $$; $ ) {
  croak "Usage: \$p = \$model->log_prob(\$text [, \$n]);"
    unless @_ == 2 or @_ == 3;
  my $self = shift;
  my $text = shift;
  my $max_n = $self->{N};
  my $n = (@_) ? shift : $self->{USE_N}; # order of model to use
  my $debug = $self->{DEBUG};

  croak "NGram model hasn't been trained yet, can't calculate probabilities."
    unless $self->{TRAINED};
  croak "Cannot apply $n-gram model (\$n parameter must be >= 1)"
    unless $n >= 1;
  croak "NGram model contains data for $self->{N}-grams only, cannot apply $n-gram model"
    if $n > $self->{N};

  $text = $self->_normalise_text($text);
  my $l = length($text);

  my $log_p_C = 0;
  if ($HAVE_NGRAMC) {
    $log_p_C = Text::NCleaner::NGramC::log_string_probability($self->{CP}, $text, $n, $self->{Q}, ($debug > 1) ? 1 : 0);
    return wantarray ? ($log_p_C, $l) : $log_p_C
      unless $debug > 0; # compare to Perl probabilities in debugging mode
  }

  my $log_p = 0;
  foreach my $i (1 .. $l) {
    my $ngram = ($i < $n) ? substr($text, 0, $i) : substr($text, $i-$n, $n);
    my $lp_ngram = $self->log_cp($ngram);
    $log_p += $lp_ngram;
    printf "\n - pC(%s) = %.2f bits   total = %.2f bits", $ngram, $lp_ngram, $log_p
      if $debug > 1; # verbose debugging
  }

  if ($debug > 0) {
    if ($HAVE_NGRAMC) {
      printf "\nlog_p(<string>) = %.2f bits (Perl) vs. %.2f bits (C)\n", $log_p, $log_p_C;
    }
    else {
      printf "\nlog_p(<string>) = %.2f bits\n", $log_p;
    }
  }

  return wantarray ? ($log_p, $l) : $log_p;
}

=item I<$cp> = I<$model>->B<cp>(I<$ngram>);

=item I<$log_cp> = I<$model>->B<log_cp>(I<$ngram>);

Estimate conditional probability (B<cp>) or its base-2 logarithm (B<log_cp>)
for the n-gram I<$ngram>, with interpolation and smoothing applied.

The conditional probability of an n-gram is defined as the probability of the
last character given the "history" of the previous n-1 characters.

=cut

sub cp {
  croak "Usage: \$cp = \$model->cp(\$ngram);"
    unless @_ == 2;
  my $self = shift;
  my $ngram = shift;
  my $debug = $self->{DEBUG};
  my $n = length($ngram);
  return 1 if $n < 1;
  croak "$n-gram '$ngram' is too long for this model."
    if $n > $self->{N};

  my $q = $self->{Q}; # interpolation factor for geometric interpolation
  my $total_p_C;
  if ($HAVE_NGRAMC) {
    $total_p_C = Text::NCleaner::NGramC::conditional_probability($self->{CP}, $ngram, $n, $q, 0);
    return $total_p_C unless $debug > 2; # compare against Perl code for insanely verbose debugging
  }

  my $norm = (1 - $q ** $n) / (1 - $q); # normalise so that weights add up to 1

  my $total_p = 0;
  my $factor = 1 / $norm;
  foreach my $i (reverse 1 .. $n) {
    my $p = $self->{CP}->[$i]->{ substr($ngram, $n - $i) } || 0;  # conditional probability for last $i characters
    $total_p += $p * $factor;
    $factor *= $q;
  }

  if ($debug > 2) {
    printf "\n   [p($ngram) = %g (Perl) vs. %g (C)]", $total_p, $total_p_C;
  }
  return $total_p;
}

sub log_cp {
  croak "Usage: \$log_cp = \$model->log_cp(\$ngram);"
    unless @_ == 2;
  my $self = shift;
  my $ngram = shift;
  my $p = $self->cp($ngram);
  die "cP($ngram) = 0.0 -- this shouldn't happen!"
    unless $p > 0;
  return log($p) / log(2); # scale to base-2 logarithm for information content interpretation
}

=back

=begin comment

The following are internal helper functions for text normalisation (_normalise_text) and
obtaining n-gram counts from a string (_count_ngrams).

=end comment

=cut

sub _normalise_text ( $$ ) {
  my $self = shift;
  my $text = shift;
  my $mode = $self->{NORMALIZE};

  $text =~ s/<[a-zA-Z]>/ /g;    # remove paragraph type markers in cleaned text
  $text =~ s/^\s+//;		# normalise whitespace
  $text =~ s/\s+$//;
  $text =~ s/\s+/ /g;
  $text =~ tr[\x00-\x1f][]d; 	# delete control characters

  if ($mode > 0) {
    $text =~ s/[^\x{20}-\x{7e}]+/~/g; # mode 1: translate all high-bit characters to "~"
    if ($mode > 1) {
      $text = lc($text); 	# mode 2/3: normalise to lowercase
      if ($mode == 2) {
	$text =~ s/[aeiou]/a/g;	# mode 2: reduce letters to vowel / consonant categories, digits to 0
	$text =~ s/[bcdfghjklmnpqrstvwxyz]/t/g;
	$text =~ s/[0-9]/0/g;
      }
      elsif ($mode == 3) {
	$text =~ s/[a-z]/a/g; 	# mode 3: reduce letters to a, digits to 0
	$text =~ s/[0-9]/0/g;
      }
    }
  }

  return $text;
}

## $n_tokens = count_ngrams($n, $text, $weight, $freq_hash);
sub _count_ngrams {
  my $n = shift;
  my $string = shift;
  my $weight = shift;		 # count weights (set to -1 for differencing)
  my $F = shift;		 # pass in existing frequency hash

  my $l = length($string);
  my $count = 0;		# number of n-gram tokens counted
  $string .= " " x ($n - 1);    # pad training data with blanks so n-gram model won't be deficient

  if ($HAVE_NGRAMC) {
    $count = Text::NCleaner::NGramC::count_ngrams($n, $string, $weight, $F);
  }
  else {
    foreach my $i (0 .. $l - 1) {
      $F->{ substr($string, $i, $n) } += $weight;
      $count++;
    }
  }

  return $count;
}

=head1 AUTHOR

Stefan Evert C<< <stefan.evert@uos.de> >>

=head1 COPYRIGHT & LICENSE

Copyright (C) 2008 by Stefan Evert, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of Text::NCleaner::NGram
