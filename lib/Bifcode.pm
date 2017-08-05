package Bifcode;
use 5.008001;
use strict;
use warnings;
use Carp;
use Exporter::Tidy all => [qw( encode_bifcode decode_bifcode force_bifcode )];

# ABSTRACT: Serialisation similar to Bencode + undef/UTF8

our $VERSION = '0.001';
our ( $DEBUG, $max_depth, $dict_key );

{
    # Shamelessly copied from JSON::PP::Boolean
    package Bifcode::Boolean;
    use overload (
        "0+"     => sub { ${ $_[0] } },
        "++"     => sub { Carp::croak 'Bifcode::Boolean is immutable' },
        "--"     => sub { Carp::croak 'Bifcode::Boolean is immutable' },
        fallback => 1,
    );
}

$Bifcode::TRUE  = bless( do { \( my $t = 1 ) }, 'Bifcode::Boolean' );
$Bifcode::FALSE = bless( do { \( my $f = 0 ) }, 'Bifcode::Boolean' );

sub _msg { sprintf "@_", pos() || 0 }

sub _decode_bifcode_chunk {
    warn _msg 'decoding at %s' if $DEBUG;

    local $max_depth = $max_depth - 1 if defined $max_depth;

    if (m/ \G ( 0 | [1-9] [0-9]* ) ( : | ; ) /xgc) {
        my $len  = $1;
        my $blob = $2 eq ';';

        croak _msg 'unexpected end of string data starting at %s'
          if $len > length() - pos();

        if ($blob) {
            my $data = substr $_, pos(), $len;
            pos() = pos() + $len;

            warn _msg BYTES => "(length $len) at %s", if $DEBUG;

            return $dict_key ? $data : \$data;
        }

        utf8::decode( my $str = substr $_, pos(), $len );
        pos() = pos() + $len;

        warn _msg
          UTF8 => "(length $len)",
          $len < 200 ? "[$str]" : (), 'at %s'
          if $DEBUG;

        return $str;
    }

    my $pos = pos();
    if (m/ \G -? 0? [0-9]+ ( : | ; ) /xgc) {
        pos() = $pos;
        croak _msg 'malformed string length at %s';
    }

    croak _msg 'dict key is not a string at %s' if $dict_key;

    if (m/ \G T /xgc) {
        warn _msg 'TRUE at %s' if $DEBUG;
        return $Bifcode::TRUE;
    }
    elsif (m/ \G F /xgc) {
        warn _msg 'FALSE at %s' if $DEBUG;
        return $Bifcode::FALSE;
    }
    elsif (m/ \G ~ /xgc) {
        warn _msg 'UNDEF at %s' if $DEBUG;
        return undef;
    }
    elsif (m/ \G i /xgc) {
        croak _msg 'unexpected end of data at %s' if m/ \G \z /xgc;

        m/ \G ( 0 | -? [1-9] [0-9]* ) , /xgc
          or croak _msg 'malformed integer data at %s';

        warn _msg INTEGER => $1, 'at %s' if $DEBUG;
        return 0 + $1;
    }
    elsif (m/ \G \[ /xgc) {
        warn _msg 'LIST at %s' if $DEBUG;

        croak _msg 'nesting depth exceeded at %s'
          if defined $max_depth and $max_depth < 0;

        my @list;
        until (m/ \G \] /xgc) {
            warn _msg 'list not terminated at %s, looking for another element'
              if $DEBUG;
            push @list, _decode_bifcode_chunk();
        }
        return \@list;
    }
    elsif (m/ \G \{ /xgc) {
        warn _msg 'DICT at %s' if $DEBUG;

        croak _msg 'nesting depth exceeded at %s'
          if defined $max_depth and $max_depth < 0;

        my $last_key;
        my %hash;
        until (m/ \G \} /xgc) {
            warn _msg 'dict not terminated at %s, looking for another pair'
              if $DEBUG;

            croak _msg 'unexpected end of data at %s'
              if m/ \G \z /xgc;

            my $key = do { local $dict_key = 1; _decode_bifcode_chunk() };

            croak _msg 'duplicate dict key at %s'
              if exists $hash{$key};

            croak _msg 'dict key not in sort order at %s'
              if defined $last_key and $key lt $last_key;

            croak _msg 'dict key is missing value at %s'
              if m/ \G \} /xgc;

            $last_key = $key;
            $hash{$key} = _decode_bifcode_chunk();
        }
        return \%hash;
    }
    else {
        croak _msg m/ \G \z /xgc
          ? 'unexpected end of data at %s'
          : 'garbage at %s';
    }
}

sub decode_bifcode {
    local $_         = shift;
    local $max_depth = shift;
    croak 'decode_bifcode: too many arguments: ' . "@_" if @_;
    croak 'decode_bifcode: only accepts bytes' if utf8::is_utf8($_);

    my $deserialised_data = _decode_bifcode_chunk();
    croak _msg 'trailing garbage at %s' if $_ !~ m/ \G \z /xgc;
    return $deserialised_data;
}

sub _encode_bifcode {
    my ($data) = @_;
    return '~' unless defined $data;

    my $type = ref $data;
    if ( $type eq '' ) {
        if ( !$dict_key and $data =~ m/\A (?: 0 | -? [1-9] [0-9]* ) \z/x ) {
            $type = 'Bifcode::INTEGER';
        }
        else {
            $type = 'Bifcode::UTF8';
        }
        $data = \( my $tmp = $data );
    }
    elsif ( $type eq 'SCALAR' ) {
        $type = 'Bifcode::BYTES';
    }

    use bytes;    # for 'sort' and 'length' below

    if ( $type eq 'Bifcode::UTF8' ) {
        my $str = $$data // croak 'Bifcode::UTF8 must be defined';
        utf8::encode($str);    #, sub { croak 'invalid Bifcode::UTF8' } );
        return length($str) . ':' . $str;
    }
    elsif ( $type eq 'Bifcode::BYTES' ) {
        croak 'Bifcode::BYTES must be defined' unless defined $$data;
        return length($$data) . ';' . $$data;
    }

    croak 'Bifcode::DICT key must be Bifcode::BYTES or Bifcode::UTF8'
      if $dict_key;

    if ( $type eq 'Bifcode::Boolean' ) {
        return $$data ? 'T' : 'F';
    }
    elsif ( $type eq 'Bifcode::INTEGER' ) {
        croak 'Bifcode::INTEGER must be defined' unless defined $$data;
        return sprintf 'i%s,', $$data
          if $$data =~ m/\A (?: 0 | -? [1-9] [0-9]* ) \z/x;
        croak 'invalid integer: ' . $$data;
    }
    elsif ( $type eq 'ARRAY' ) {
        return '[' . join( '', map _encode_bifcode($_), @$data ) . ']';
    }
    elsif ( $type eq 'HASH' ) {
        return '{' . join(
            '',
            map {
                do {
                    local $dict_key = 1;
                    _encode_bifcode($_);
                  }, _encode_bifcode( $data->{$_} )
              }
              sort keys %$data
        ) . '}';
    }
    else {
        croak 'unhandled data type: ' . $type;
    }
}

sub encode_bifcode {
    croak 'need exactly one argument' if @_ != 1;
    goto &_encode_bifcode;
}

sub force_bifcode {
    my $ref  = shift;
    my $type = shift;

    croak 'ref and type must be defined' unless defined $ref and defined $type;
    bless \$ref, 'Bifcode::' . uc($type);
}

decode_bifcode('i1,');

__END__

=pod

=encoding utf8

=head1 NAME

Bifcode - simple serialization format

=head1 VERSION

0.001 (yyyy-mm-dd)


=head1 SYNOPSIS

    use Bifcode qw( encode_bifcode decode_bifcode );
 
    my $bifcode = encode_bifcode {
        bools   => [ $Bifcode::FALSE, $Bifcode::TRUE, ],
        bytes   => \pack( 's<', 255 ),
        integer => 25,
        undef   => undef,
        utf8    => "\x{df}",
    };

    # 7b 35 3a 62 6f 6f 6c 73 5b 46 54 5d    {5:bools[FT]
    # 35 3a 62 79 74 65 73 32 3b ff  0 37    5:bytes2;..7
    # 3a 69 6e 74 65 67 65 72 69 32 35 2c    :integeri25,
    # 35 3a 75 6e 64 65 66 7e 34 3a 75 74    5:undef~4:ut
    # 66 38 32 3a c3 9f 7d                   f82:..}

    my $decoded = decode_bifcode $bifcode;

=head1 STATUS

This module and related encoding format are still under development. Do
not use it anywhere near production. Input is welcome.

=head1 DESCRIPTION

Bifcode implements the I<bifcode> serialisation format, a mixed
binary/text encoding with support for the following data types:

=over

=item * Undefined(null)

=item * Booleans(true/false)

=item * Integers

=item * UTF8-encoded strings

=item * Opaque(binary) data strings

=item * Arrays(lists) and hashes(dictionaries)

=back

The encoding is simple to construct and relatively easy to parse. No
characters need escaping. It is not considered human readable.  It is
bijective, meaning that there is only one encoding for a data
structure. This last property makes it suitable for comparing data
structures (using cryptographic hashes) across networks.

In terms of size the encoding is similar to minified JSON. In terms of
speed this module compares well with other pure Perl encoding modules
with the same features.

The encoding is defined as follows:

=head2 BIFCODE_UNDEF

A null or undefined value correspond to '~'.

=head2 BIFCODE_TRUE and BIFCODE_FALSE

Boolean values are represented by 'T' and 'F'.

=head2 BIFCODE_UTF8

A UTF8 string is the octet length of the decoded string as a base ten
number followed by a colon and the decoded string.  For example "ß"
corresponds to "2:\x{c3}\x{9f}".

=head2 BIFCODE_BYTES

Opaque data is the octet length of the data as a base ten number
followed by a semicolon and then the data itself. For example a
three-byte blob 'xyz' corresponds to '3;xyz'.

=head2 BIFCODE_INTEGER

Integers are represented by an 'i' followed by the number in base 10
followed by a ','. For example 'i3,' corresponds to 3 and 'i-3,'
corresponds to -3. Integers have no size limitation. 'i-0,' is invalid.
All encodings with a leading zero, such as 'i03,', are invalid, other
than 'i0,', which of course corresponds to 0.

=head2 BIFCODE_LIST

Lists are encoded as a '[' followed by their elements (also I<bifcode>
encoded) followed by a ']'. For example '[4:spam4:eggs]' corresponds to
['spam', 'eggs'].

=head2 BIFCODE_DICT

Dictionaries are encoded as a '{' followed by a list of alternating
keys and their corresponding values followed by a '}'. For example,
'{3:cow3:moo4:spam4:eggs}' corresponds to {'cow': 'moo', 'spam':
'eggs'} and '{4:spam[1:a1:b]}' corresponds to {'spam': ['a', 'b']}.
Keys must be BIFCODE_UTF8 or BIFCODE_BYTES and appear in sorted order
(sorted as raw strings, not alphanumerics).

=head1 INTERFACE

=head2 C<encode_bifcode( $datastructure )>

Takes a single argument which may be a scalar, or may be a reference to
either a scalar, an array or a hash. Arrays and hashes may in turn
contain values of these same types. Returns a byte string.

The mapping from Perl to I<bifcode> is as follows:

=over

=item * 'undef' maps directly to BIFCODE_UNDEF.

=item * The global package variables C<$Bifcode::TRUE> and C<$Bifcode::FALSE>
encode to BIFCODE_TRUE and BIFCODE_FALSE.

=item * Plain scalars that look like canonically represented integers
will be serialised as BIFCODE_INTEGER. Otherwise they are treated as
BIFCODE_UTF8.

=item * SCALAR references become BIFCODE_BYTES.

=item * ARRAY references become BIFCODE_LIST.

=item * HASH references become BIFCODE_DICT.

=back

You can force scalars to be encoded a particular way by passing a
reference to them blessed as Bifcode::BYTES, Bifcode::INTEGER or
Bifcode::UTF8. The C<force_bifcode> function below can help with
creating such references.

This subroutine croaks on unhandled data types.

=head2 C<decode_bifcode( $string [, $max_depth ] )>

Takes a byte string and returns the corresponding deserialised data
structure.

If you pass an integer for the second option, it will croak when
attempting to parse dictionaries nested deeper than this level, to
prevent DoS attacks using maliciously crafted input.

I<bifcode> types are mapped back to Perl in the reverse way to the
C<encode_bifcode> function, with the exception that any scalars which
were "forced" to a particular type (using blessed references) will
decode as unblessed scalars.

Croaks on malformed data.

=head2 C<force_bifcode( $scalar, $type )>

Returns a reference to $scalar blessed as Bifcode::$TYPE. The value of
$type is not checked, but the C<encode_bifcode> function will only
accept the resulting reference where $type is one of 'bytes',
'integer', or 'utf8'.

=head1 DIAGNOSTICS

=over

=item C<trailing garbage at %s>

Your data does not end after the first I<encode_bifcode>-serialised
item.

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

Your data violates the I<encode_bifcode> format constaint that dict
keys must appear in lexical sort order.

=item C<duplicate dict key at %s>

Your data violates the I<encode_bifcode> format constaint that all dict
keys must be unique.

=item C<dict key is not a string at %s>

Your data violates the I<encode_bifcode> format constaint that all dict
keys be strings.

=item C<dict key is missing value at %s>

Your data contains a dictionary with an odd number of elements.

=item C<nesting depth exceeded at %s>

Your data contains dicts or lists that are nested deeper than the
$max_depth passed to C<decode_bifcode()>.

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
C<encode_bifcode()> has to resort to a heuristic to decide how to
serialise a scalar. This cannot be fixed.

=head1 AUTHOR

Mark Lawrence <nomad@null.net>, heavily based on Bencode by Aristotle
Pagaltzis <pagaltzis@gmx.de>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c):

=over

=item * 2015 by Aristotle Pagaltzis

=item * 2017 by Mark Lawrence.

=back

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
