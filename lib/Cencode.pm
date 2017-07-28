package Cencode;
use 5.006;
use strict;
use warnings;
use Carp;
use Exporter::Tidy all => [qw( cencode cdecode )];

# ABSTRACT: Serialisation similar to Bencode + undef/UTF8

our $VERSION = '0.001';
our ( $DEBUG, $max_depth );
my $EOC = ',';    # End Of Chunk

sub _msg { sprintf "@_", pos() || 0 }

sub _cdecode_string {

    if (m/ \G ( 0 | [1-9] \d* ) : /xgc) {
        my $len = $1;

        croak _msg 'unexpected end of string data starting at %s'
          if $len > length() - pos();

        my $str = substr $_, pos(), $len;
        pos() = pos() + $len;

        warn _msg
          STRING => "(length $len)",
          $len < 200 ? "[$str]" : ()
          if $DEBUG;

        return $str;
    }

    my $pos = pos();
    if (m/ \G -? 0? \d+ : /xgc) {
        pos() = $pos;
        croak _msg 'malformed string length at %s';
    }
    return;
}

sub _cdecode_chunk {
    warn _msg 'decoding at %s' if $DEBUG;

    local $max_depth = $max_depth - 1 if defined $max_depth;

    if ( defined( my $str = _cdecode_string() ) ) {
        return $str;
    }
    elsif (m/ \G ~ /xgc) {
        warn _msg 'UNDEF' if $DEBUG;
        return undef;
    }
    elsif (m/ \G i /xgc) {
        croak _msg 'unexpected end of data at %s' if m/ \G \z /xgc;

        m/ \G ( 0 | -? [1-9] \d* ) $EOC /xgc
          or croak _msg 'malformed integer data at %s';

        warn _msg INTEGER => $1 if $DEBUG;
        return $1;
    }
    elsif (m/ \G l /xgc) {
        warn _msg 'LIST' if $DEBUG;

        croak _msg 'nesting depth exceeded at %s'
          if defined $max_depth and $max_depth < 0;

        my @list;
        until (m/ \G $EOC /xgc) {
            warn _msg 'list not terminated at %s, looking for another element'
              if $DEBUG;
            push @list, _cdecode_chunk();
        }
        return \@list;
    }
    elsif (m/ \G d /xgc) {
        warn _msg 'DICT' if $DEBUG;

        croak _msg 'nesting depth exceeded at %s'
          if defined $max_depth and $max_depth < 0;

        my $last_key;
        my %hash;
        until (m/ \G $EOC /xgc) {
            warn _msg 'dict not terminated at %s, looking for another pair'
              if $DEBUG;

            croak _msg 'unexpected end of data at %s'
              if m/ \G \z /xgc;

            my $key = _cdecode_string();
            defined $key or croak _msg 'dict key is not a string at %s';

            croak _msg 'duplicate dict key at %s'
              if exists $hash{$key};

            croak _msg 'dict key not in sort order at %s'
              if defined $last_key and $key lt $last_key;

            croak _msg 'dict key is missing value at %s'
              if m/ \G $EOC /xgc;

            $last_key = $key;
            $hash{$key} = _cdecode_chunk();
        }
        return \%hash;
    }
    else {
        croak _msg m/ \G \z /xgc
          ? 'unexpected end of data at %s'
          : 'garbage at %s';
    }
}

sub cdecode {
    local $_         = shift;
    local $max_depth = shift;
    croak 'cdecode: too many arguments: ' . "@_" if @_;

    my $deserialised_data = _cdecode_chunk();
    croak _msg 'trailing garbage at %s' if $_ !~ m/ \G \z /xgc;
    return $deserialised_data;
}

sub _cencode {
    my ($data) = @_;

    return '~' unless defined $data;

    if ( not ref $data ) {
        return sprintf 'i%s' . $EOC, $data
          if $data =~ m/\A (?: 0 | -? [1-9] \d* ) \z/x;
        return length($data) . ':' . $data;
    }
    elsif ( ref $data eq 'SCALAR' ) {

        # escape hatch -- use this to avoid num/str heuristics
        return length($$data) . ':' . $$data;
    }
    elsif ( ref $data eq 'ARRAY' ) {
        return 'l' . join( '', map _cencode($_), @$data ) . $EOC;
    }
    elsif ( ref $data eq 'HASH' ) {
        return 'd'
          . join( '',
            map { _cencode( \$_ ), _cencode( $data->{$_} ) } sort keys %$data )
          . $EOC;
    }
    else {
        croak 'unhandled data type';
    }
}

sub cencode {
    croak 'need exactly one argument' if @_ != 1;
    goto &_cencode;
}

cdecode( 'i1' . $EOC );

__END__

=pod

=head1 SYNOPSIS

 use Cencode qw( cencode cdecode );
 
 my $cencoded = cencode { 'age' => 25, 'eyes' => 'blue' };
 print $cencoded, "\n";
 my $decoded = cdecode $cencoded;


=head1 DESCRIPTION

This module implements the BitTorrent I<cencode> serialisation format,
as described in
L<http://www.bittorrent.org/beps/bep_0003.html#bencoding>.

=head1 INTERFACE

=head2 C<cencode( $datastructure )>

Takes a single argument which may be a scalar, or may be a reference to
either a scalar, an array or a hash. Arrays and hashes may in turn
contain values of these same types. Plain scalars that look like
canonically represented integers will be serialised as such. To bypass
the heuristic and force serialisation as a string, use a reference to a
scalar.

Croaks on unhandled data types.

=head2 C<cdecode( $string [, $max_depth ] )>

Takes a string and returns the corresponding deserialised data
structure.

If you pass an integer for the second option, it will croak when
attempting to parse dictionaries nested deeper than this level, to
prevent DoS attacks using maliciously crafted input.

Croaks on malformed data.

=head1 DIAGNOSTICS

=over

=item C<trailing garbage at %s>

Your data does not end after the first I<cencode>-serialised item.

You may also get this error if a malformed item follows.

=item C<garbage at %s>

Your data is malformed.

=item C<unexpected end of data at %s>

Your data is truncated.

=item C<unexpected end of string data starting at %s>

Your data includes a string declared to be longer than the available
data.

=item C<malformed string length at %s>

Your data contained a string with negative length or a length with
leading zeroes.

=item C<malformed integer data at %s>

Your data contained something that was supposed to be an integer but
didn't make sense.

=item C<dict key not in sort order at %s>

Your data violates the I<cencode> format constaint that dict keys must
appear in lexical sort order.

=item C<duplicate dict key at %s>

Your data violates the I<cencode> format constaint that all dict keys
must be unique.

=item C<dict key is not a string at %s>

Your data violates the I<cencode> format constaint that all dict keys
be strings.

=item C<dict key is missing value at %s>

Your data contains a dictionary with an odd number of elements.

=item C<nesting depth exceeded at %s>

Your data contains dicts or lists that are nested deeper than the
$max_depth passed to C<cdecode()>.

=item C<unhandled data type>

You are trying to serialise a data structure that consists of data
types other than

=over

=item *

scalars

=item *

references to arrays

=item *

references to hashes

=item *

references to scalars

=back

The format does not support this.

=back

=head1 BUGS AND LIMITATIONS

Strings and numbers are practically indistinguishable in Perl, so
C<cencode()> has to resort to a heuristic to decide how to serialise a
scalar. This cannot be fixed.

