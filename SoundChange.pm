package Lingua::SoundChange;

use 5.005_03;
use strict;
use Carp;
# use warnings;

# for debugging:
use constant PRINT_RULES => $ENV{LINGUA_SOUNDCHANGE_PRINTRULES} || 0;
use constant DEBUG => 0;

$Lingua::SoundChange::VERSION = '0.01';

sub new {
    my($class, $vars, $rules, $opts) = @_;

    $opts ||= { };

    croak '$vars must be a hash reference!' unless ref $vars eq 'HASH';
    croak '$rules must be an array reference!' unless ref $rules eq 'ARRAY';

    my $obj = {
        raw_vars  => $vars,
        raw_rules => $rules,
        opts      => $opts,
    };

    $obj->{vars}     = compile_vars($vars);
    ( $obj->{rules},
      $obj->{code} ) = compile_rules($rules, $obj->{vars}, $obj->{raw_vars}, $opts);

    bless $obj, $class;
}

sub change {
    my($self, $words) = @_;

    $words = [] unless defined $words;

    croak("change needs an array reference") unless ref($words) eq 'ARRAY';

    foreach my $word (@$words) {
        foreach my $rule (@{$self->rules}) {
            if($self->keep) {
                $word = [ $word, $rule->($word) ];
            } else {
                $word = $rule->($word);
            }
        }
    }

    $words;
}


# Private methods

sub compile_rules {
    my($rules, $vars, $varstring, $opt) = @_;

    croak "rules not an array reference" unless ref $rules eq 'ARRAY';
    croak "vars not a hash reference" unless ref $vars eq 'HASH';
    croak "varstring not a hash reference" unless ref $varstring eq 'HASH';
    croak "opt not a hash reference" unless ref $opt eq 'HASH';

    my @compiledrules;
    my %code;

    # Rules: change from a sound (one or more letters) or a category
    # to another sound or category, in a certain environment.
    # Categories may only be one letter long and are usually uppercase.
    # Environments must contain a _ symbol to show where the replacement
    # takes place; it may also contain letters, categories, and the special
    # symbols ( ) (to enclose optional parts) and # (beginning or end of
    # word).
    # Rules can only change sounds to sounds, and categories to categories.
    # If a category is to be changed to another category, they should be
    # the same length. Otherwise the second category will have its laster
    # letter repeated until it has the same length as the first (if it is
    # shorter), or characters in the second category that don't match
    # characters in the first will not be produced by such a range. Note
    # that this is an artefact of the use of tr/// and is not guaranteed
    # behaviour.
    # Don't use regex metacharacters (except for the parentheses which
    # show optional elements) in the environment or in names of categories
    # or sounds.
    # These include: . * + ? ^ $ [ ]

    foreach my $rule (@$rules) {
        if( $rule =~ m{
                ^
                ( [^/]+ )   # "change from" to $1
                /           # slash
                ( [^/]* )   # "change to" to $2 (may be blank)
                /           # slash
                ( .+ )      # "environment" to $3 (may not be blank)
                $
              }x )
        {
            my($from, $to, $env) = ($1, $2, $3);
            my($subfrom, $subto) = ('', '');

            my $option = sub {
                my $word = shift;

                # Change parentheses round one element to a question
                # mark following it, ...
                $word =~ s{
                    \(  # open parenthesis
                    (.) # one character, to $1
                    \)  # close parenthesis
                }{
                    $1 . '?'
                }gex;

                # ... and parentheses around multiple elements by
                # non-capturing parentheses followed by a question mark
                # (but nested parentheses are not allowed!)
                $word =~ s{
                    \(          # open parenthesis
                    ( [^()]+ )  # one or more non-parenthesis characters,
                                # to $1
                    \)          # close parenthesis
                }{
                    '(?:' . $1 . ')?'
                }gex;

                $word;
            };

            # Escape dollar signs and at signs in $env, which would
            # otherwise try to interpolate a variable into the regular
            # expression
            $env =~ s/([\$\@])/\\$1/g;

            # Get the bits before and after the underscore
            # and put them in capturing parentheses in $subfrom
            if($env =~ /^(#?)([^_#]*)(_)([^_#]*)(#?)$/) {
                # leading #
                $subfrom .= '^' if defined $1 && length $1;

                # pre-environment
                $subfrom .= '(' . $option->(quotemeta $2) . ')';

                # underscore
                $subfrom .= "(\Q$from\E)";

                # post-environment
                $subfrom .= '(' . $option->(quotemeta $4) . ')';

                # trailing #
                $subfrom .= '$' if defined $5 && length $5;
            }

            # Now expand categories
            $subfrom =~ s{(\\?)(.)}{$vars->{$2} || $1 . $2}eg;

            # Show where the rule matches, if desired
            if($opt->{printRules}) {
                $subto .= qq(print "\Q$from\E->\Q$to\E /\Q$env\E applies to \$word at ", (length(\$`)+1), "\\n"; );
            }

            $subto .= '$1 . ';
            $subto .= ($vars->{$from} ? "do { my \$char = \$2; \$char =~ tr{$varstring->{$from}}{" . ($varstring->{$to} || $to) . "}; \$char }"
                                      : "q{" . $to . "}");
            $subto .= ' . $3';

            if(PRINT_RULES) {
                print "[", $#compiledrules + 1, "] $rule --> s{$subfrom}{$subto}eg\n";
            }

            my $code = <<"EOF";
sub {
    my \$word = shift;
    my \$orig;
    # print qq(Working on '\$word'; \Q$from\E->\Q$to\E /\Q$env\E; from is '\Q$subfrom\E and to is '\Q$subto\E'\\n);
    1 while ((\$orig = \$word) =~ s{$subfrom}{$subto}e) && (\$orig ne \$word) && (\$word = \$orig);
    \$word;
}
EOF

            push @compiledrules, eval $code;
            croak "Problem with '$code'" unless $compiledrules[-1];
            $code{$compiledrules[-1]} = $code;
        }
    }

    ( \@compiledrules, \%code );
}

sub compile_vars {
    my($vars) = @_;

    croak "not a hash reference" unless ref $vars eq 'HASH';

    my %compiledvars;

    foreach my $var (keys %$vars) {
        my $list = $vars->{$var};
        # Escape at signs and dollars in the list
        $list =~ s/([\$\@])/\\$1/g;

        $compiledvars{$var} = qr/[$list]/;

        if(PRINT_RULES) {
            print "($var => $list // $compiledvars{$var})\n";
        }
    }

    \%compiledvars;
}

sub rules {
    my($self) = @_;

    $self->{rules};
}

sub vars {
    my($self) = @_;

    $self->{vars};
}

sub varstring {
    my($self) = @_;

    $self->{raw_vars};
}

sub keep {
    my($self) = @_;

    $self->{opts}->{keep};
}

sub printRules {
    my($self) = @_;

    $self->{opts}->{printRules};
}

sub code {
    my($self, $token, $code) = @_;

    $self->{code}->{$token} = $code if $code;

    $self->{code}->{$token};
}


1;
__END__
# Below is stub documentation for your module. You better edit it!

=head1 NAME

Lingua::SoundChange - Create regular sound changes

=head1 SYNOPSIS

  use Lingua::SoundChange;

  my $lat2port = Lingua::SoundChange->new($variables, $rules);
  # or
  my $lat2port = Lingua::SoundChange->new($variables, $rules, $options);

  my $translation = $lat2port->change($original);

=head1 DESCRIPTION

=head2 Introduction

This module is a sound change applier. With it, you can construct
objects which will generate consistent sound changes. One way to use
this is, for example, to simulate the sound change from one language
to another (such as from Latin to Portuguese). It was inspired by
Mark Rosenfelder's sound change applier program; see L</"SEE ALSO">
for more information and a URL.

This module has an object-oriented interface. To use it, construct
a Lingua::SoundChange object, which you can then use to apply sound
changes to words. You can also have several different sound change
objects around simultaneously, for example, to show sound change from
a parent language to several different daughter languages, each with
different sound change rules.

=head2 Methods

=head3 new(HASHREF, ARRAYREF [, HASHREF])

The constructor new creates a new Lingua::SoundChange object. It takes
two or three parameters: a hash ref, an array ref, and another (optional)
hash ref.

=over 4

=item variables

The first parameter is a hash ref listing zero or more "variables".
These are one-character short cuts for character classes. For example,
you could define S to be any stop, or F to be any front vowel. These
are useful in the ruleset, described below. If you do not wish to use
any variables, pass in a reference to an empty hash as the first
parameter of the constructor.

Variables are often given capital letters to distinguish them from
the "data" letters used in the rules, which are usually lowercase.
This is not a requirement; however, note that if you have a source
letter with the same name as a variable, the behaviour is undefined.

The keys of this hash ref are the names of the variables; the values
are a string of letters which make up the variable. This is similar
to a character range in Perl's regular expression (e.g. [aeiou] for
a vowel); however, you should not include the brackets in the value.

For example, to make C<V> a list of voiced consonants and C<U> a list
of corresponding unvoiced consonants, you could pass something like
this to C<new>:

  { V => 'ptk', U => 'bdg' }

=item rules

The second parameter is an array ref listing zero or more "rules".
These rules describe which sound changes to apply in which environments.
The sound changes will be applied in the order in which these rules
are presented.

For more information on the format of these rules, see L</"Format of
sound change rules">.

B<NOTE>: Do not use characters in the rules or variable names
which are special to regular expressions. This includes the
following characters: C<. * + ? [ ] { } ( )>. (Exception: the use
of parentheses to mark something as optional in an environment.)

=item options

The third, optional, parameter is a hash ref of options which control
what data is output or in which format the translated words are returned.
Each key in the hash takes a Boolean value (true or false).

Possible options are:

=over 4

=item printRules

Whether to print out (to STDOUT) which rule applies to each word, and 
at which character position, during matching.

The output will look like this:

  s-> /_# applies to secundus at 7 

This will use $`, which will incur a slight time penalty for all
regular expressions in your script.

Default: false.

=item keep

If this option is set to a true value, then the list of returned items
will be a list of array refs, each containing two elements: first the
original word as passed in to the C<change> method, and second the
(possibly transformed) word. Otherwise, the result list will contain
only the (possibly transformed) word.

Default: false.

=back

=back

The constructor returns a new Lingua::SoundChange object on success.
On failure, the constructor will croak.

=head3 change(ARRAYREF)

Once you have constructed a Lingua::SoundChange object, you can use it
to apply the sound changes you have described on words.

Pass in an array ref with one word per array element.
The sound changes specified in the constructor will be applied to each
word in turn. The result will be an arrayref containing the transformed
words.

Note that this method does not do any splitting of text into words for
you; this is left up to you. The reason for this is that the concept of
a B<word> is left up to the user of the module. A simple case would be
"a sequence of \w characters" or "a sequence of non-space characters".

=head2 EXPORT

None.

This module only has an object-oriented interface and does not export
anything.

=head1 LONG EXPLANATION

The following explanation is largely taken from Mark Rosenfelder's own
description of his sound change applier program C<sounds>, and modified as
appropriate for this module. The B<I> in the following narrative is
Mark's, not mine.

=head2 Basic operation

C<Lingua::SoundChange> takes words as input, applies a set of sound
changes described in variables and rules, and returns a set of
modified words.

For instance, C<Lingua::SoundChange> will take the input data, variables,
and rules on the left and produce the output on the right:

  Input         Variables               Output

  lector        V => 'aeiou'            leitor
  doctor        C => 'ptcqbdgmnlrhs'    doutor
  focus         F => 'ie'               fogo
  jocus         B => 'ou'               jogo
  districtus    S => 'ptc'              distrito
  civitatem     Z => 'bdg'              cidade
  adoptare                              adotar
  opera         Rules                   obra
  secundus                              segundo
                s//_#
                m//_#
                e//Vr_#
                v//V_V
                u/o/_#
                gn/nh/_
                S/Z/V_V
                c/i/F_t
                c/u/B_t
                p//V_t
                ii/i/_
                e//C_rV

=head3 Format of sound change rules

Hopefully, the format of the rules will be familiar to any linguist.
For instance, here's one sound change:

  c/g/V_V

This rule says to change C<c> to C<g> between vowels. (We'll see how
to generalize this rule below.)

More generally, a sound change looks like this:

  x/y/z

where C<x> is the thing to be changed, C<y> is what it changes to,
and C<z> is the environment.

The C<z> part must always contain an underline C<_>, representing the
part that changes. That can be all there is, as in

  gn/nh/_

which tells the module to replace C<gn> with C<nh> unconditionally.

The character C<#> represents the B<beginning or end> of the word. So

  u/o/_#

means to replace C<u> with C<o>, but only at the end of the word.

The middle (C<y>) part can be B<blank>, as in

  s//_#

This means that C<s> is B<deleted> when it ends a word.

=head3 Variables

The evironment (the C<z> part) can contain B<variables>, like C<V>
above. These are defined in the first parameter to the constructor.
I use capital letters for this, though this is not a requirement.
Variables can only be one character long. You can defined any variables
needed to state your sound changed. E.g. you could define C<S> to be
any stop, or C<K> for any coronal, or whatever.

So the variable definition and rule

  F => 'ie'

  c/i/F_t

means that C<c> changes to C<i> after a front vowel and before a C<t>.

You can use variables in the first two parts as well. For instance,
suppose you've defined

  S => 'ptc',
  Z => 'bdg'

  S/Z/V_V

This means that the stops C<ptc> change to their voiced equivalents
C<bdg> between vowels. In this usage, the variables must correspond
one for one--C<p> goes to C<b>, C<t> goes to C<d>, etc. Each character
in the replacement variable (here C<Z>) gives the transformed value
of each character in the input variable (here C<S>). Make sure the two
variable definitions are the same length!

A variable can also be set to a fixed value, or deleted. E.g.

  Z//V_V

says to delete voiced stops between vowels, and

  Z/?/V_V

would translate all voiced stops between vowels to a glottal stop C<?>.

=head3 Rule order

Rules apply in the B<order> they're listed. So, with the word C<opera>
and the rules

  p/b/V_V
  e//C_rV

the first rule voices the C<p>, resulting in C<obera>; the second
deletes an C<e> between a consonant and an intervocalic C<r>, resulting
in C<obra>.

The C<printRules> option can assist in debugging rules, since it causes
the output to show exactly what rules applied to each word.

=head3 Optional elements in the environment

One or more elements in the environment can be marked as B<optional>
with parentheses. E.g.

  u/ь/_C(C)F

says to change C<u> to C<ь> when it's followed by one or two
consonants and then a front vowel.

=head2 How to use it

The module is simple-minded and yet powerful... in fact it's powerful
in part I<because> it's simple-minded. You can do a lot with these basic
pieces.

=head3 Input orthography

For instance, you may wonder whether the input data should be based on
spellings or phonemes. It doesn't matter: the program applies its changes
to whatever you give it. In my example I used conventional spellings,
but I could just as easily have used a phonemic rendering. Similarly, I
wrote the rules to output orthographic Portuguese, simply to make for
an easy example. It would be better to output a phonetic representation.
This would help us realize that we really need a sound change

  k/s/_F

that would handle the change from C<civitatem> with /k/ to
C<cidade> with /s/.

The module will handle whatever you put into it, including accented
characters. If the language you're working with requires a special font,
simply edit the source and output data with an editor, using that font.
This would allow you to use (say) an IPA font.

To improve my Latin-to-Portuguese rules, for instance, I would certainly
want to handle vowel length and stress. I might use accented vowels for
this. Of course the program knows nothing about phonetics, so you have to
remember to define the variables to match how you've set up the input
data. If you use accented vowels, you will want to change the definition
of C<V>.

=head3 Using digraphs

Though sound changes can refer to B<digraphs>, variables can't include
them. So, for instance, the following rule is intended to delete an C<i>
onset following an intervocalic consonant:

  i//VC_V

However, it won'f affect (say) C<achior>, because the C<C> will not
match the digraph C<ch>. You could write extra rules to handle the
digraphs; but it's often more convenient to use an orthography where
every phoneme corresponds to a single character.

You can write transformation rules at the beginning of your sound change
rules to transform digraphs in the input data:

  ph/f/_

=head3 Using C<Lingua::SoundChange> for conlang development

To create a child language from a parent, create some input data
containing the vocabulary of the parent, then a list of variables and
rules containing the sound changes you want to apply. Now use
C<Lingua::SoundChange> to generate the child language's vocabulary.

For example, you can download a vocabulary of Methaiun
(ftp://ftp.enteract.com/users/markrose/metaiun.lex) and the sound changes
for Kebreni (ftp://ftp.enteract.com/users/markrose/kebreni.sc). You can
compare this to the Kebreni grammar (http://www.zompist.com/kebreni.htm)
in Virtual Verduria (http://www.zompist.com/virtuver.htm).

For me, there is a peculiar, intense pleasure in creating a daughter
language with a particular feel to it, merely by altering the set of
sound changes. All I can think of to compare it to is creating new
animals indirectly, by mutating their DNA.

What sort of sound changes should you use? You can examine the history
of any language family for ideas. Some common changes that can form
part of your repertoire (with some sample C<Lingua::SoundChange> rules):

=over 4

=item Lenition

Stops become frivatives; unvoiced consonants become voiced; stops erode
into glottal stops, or C<h>, or disappear. The intervocalic position is
especially prone to change.

  S/Z/V_V

=item Palatalization

Consonants can palatalize before or after a front vowel C<i e>, perhaps
ending up as an affricate or fricative.

  k/з/_F

=item Monophthongization.

Diphthongs tend to simplify. This rule is fun to apply I<after> letting
the vanished sounds affece adjoining consonants.

  i//CV_C

=item Assimilation

Consonants change to match the place or type of articulation of an
adjoining consonant.

  D => 'td'

  m/n/_D

=item Nasalization

A nasal consonant can disappear, after nasalizing the previous vowel.

  'В' => 'вкофы',
  N => 'mn'

  V/В/_N
  N//В_

=item Umlaut

A vowel changes to match the rounding of the next vowel in the word.

  u/ь/_C(C)i

=item Vowel shifts

One vowel can migrate into a free area of the vowel space, perhaps
dragging others behind it.

  a/&/_
  o/a/_
  u/o/_

=item Tonogenesis

One way tones can originate is for voiced consonants to induce the next
vowel to be pronounced in a low pitch.

  Z => 'bdgzvmnlr',
  V => 'aiu',
  L => 'бнъ'

  V/L/Z_

=item Loss of unstressed syllables

  A => 'бйнуъ'

  V//AC(C)_

=item Loss of final sounds

This can really mess up your carefully worked out inflectional system.

  V//_#

=back

The beauty part of using C<Lingua::SoundChange> is that your language
will illustrate the Neo-Grammarian principle: sound changes apply
uniformly whenever their conditions are met. You may choose to edit the
results by hand, however, to simulate the complications of real
languages. B<Analogy> can regularize the grammar; words may be borrowed
from B<another dialect> where different changes applied; words may be
B<reborrowed> from the parent language by scholars.

I pay particular attention to the havoc the sound changes are likely to
wreak on the B<inflectional system>. E.g. if a case distinction is
maintained in some words and lost in others, it may spread to the second
category by analogy.

Sound changes can also result in B<homonyms>. For instance, if you voice
intervocalic consonants, C<meta> and C<meda> will merge. You can simply
live with this, but if the merger is particularly awkward, the users of
the language are likely to invent a new word to replace one of the
homonyms. E.g. Latin American Spanish has innovated C<cocinar> "to cook",
since the original C<cocer> has merged with C<coser> "to sew".

=head3 Using C<Lingua::SoundChange> to find spelling rules

I've also used C<sounds> to model the spelling rules of English. Here
the input file lists the spellings of several thousand English words,
and the "sound changes" are rules for turning those spellings into a
phonetic representation of how the words sound.

Most people think English spelling hopeless; but in fact the rules
predict the correct pronunciation of the word 60% of the time, and make
only minor errors (e.g. insufficient vowel reduction) another 35% of the
time.

A discussion of the rules, including the input and output files, is at
http://www.zompist.com/spell.html .

=head1 DIFFERENCE

This section lists the differences between Mark Rosenfelder's C<sounds>
program and C<Lingua::SoundChange>, and how to convert from C<sounds>
input and instructions to C<Lingua::SoundChange>.

=head2 Form of input

C<sounds> takes two input files (F<xxx.lex> and F<yyy.sc>) and produces
output on standard output (unless the B<-f> option is given) and to a file
F<yyy.out>. F<xxx.lex> is the lexicon of the input language, and F<yyy.sc>
contains the variables and sound changes and possibly comments.

C<Lingua::SoundChange> splits these two up; the sound change file
F<yyy.sc> is passed to the constructor C<new> while the lexicon
F<xxx.lex> is passed to C<change>. Also, variables and rules are
passed to C<new> separately.

=head2 Variables and rules

F<yyy.sc>, the sound change file accepted by C<sounds>, may contain
a mixture of variables (which must precede all rules), rules, and
comments. Comments are marked by an asterisk C<*> at the beginning of
the line.

C<Lingua::SoundChange> requires these two to be split up, and does
not accept comments explicitly. However, if the list of sound changes
is inside a Perl script, Perl comments can, of course, be used.

=head3 Converting a sound change file on-the-fly

Here's a simple way to convert a F<yyy.sc> file on-the-fly into
something which is suitable as input to C<new>.

  my(%vars, @rules);
  open SC, '<port.sc' or die "Can't open port.sc: $!";
  while(<SC>) {
    next if /^\*/;    # skip comment line
    next unless /\S/; # skip blank lines;
    chomp;
    if(/^(.)=(.+)$/) {
      $vars{$1} = $2;
    } elsif(m{^[^/]+/[^/]*/.+$}) {
      push @rules, $_;
    }
  }

=head3 Specifying variables and rules in-line

If you specify variables and rules inside your script, rather than
reading them in from some external source, you can use Perl comments
in appropriate places if you wish. For example, you could translate

  * Vowels
  V=aeiou
  * Consonants
  C=bcdfghjklmnpqrstvwxyz

to

  {
    # Vowels
    V => 'aeiou',
    # Consonants
    C => 'bcdfghjklmnpqrstvwxyz',
  }

and

  * Lenition
  S/Z/V_V
  * Palatalization
  k/з/_F

to

  [
    # Lenition
    'S/Z/V_V',
    # Palatalization
    'k/з/_F',
  ]

.

=head2 Splitting up words

C<sounds> assumes that F<xxx.lex> will contain one word per line. It
does not attempt to split words according to any rules; everything in
one line is treated as one word. Therefore, converting a C<sounds>
F<.lex> file to input for C<Lingua::SoundChange> is simple; it could
be done like this, for example:

  open LEX, '<latin.lex' or die "Can't read latin.lex: $!";
  my @words = <LEX>;
  chomp(@words);

Now \@words can be passed in to C<change> as a list of words to
transform.

=head2 Format of output

C<sounds> outputs results like this:

  lector --> leitor

(or like this:

  leitor [lector]

if the B<-b> switch was passed. C<Lingua::SoundChange> normally
outputs nothing, instead returning simply C<'leitor'> or (if the
C<keep> option was specified, C<[ 'lector', 'leitor' ]>). It
is up to the caller to format the output if this is desired.

=head2 Command-line switches

C<sounds> takes several command-line switches:

=over 4

=item -p

This tells C<sounds> to print out which rules apply to each word.
Use the C<printRules> option in C<Lingua::SoundChange> for this.

=item -b

This causes C<sounds> to print the original word in brackets
behind the changed word, rather than before the changed word and
an arrow.

This switch is not supported directly by C<Lingua::SoundChange>;
format the output as you desire.

=item -l

This switch causes C<sounds> to omit the original word from the
output, leaving only transformed words. In effect,
C<Lingua::SoundChange> behaves as if this is always on, unless
you specify the C<keep> option.

=item -f

This switch causes C<sounds> to write its output only to
F<yyy.out> and not also to the screen.

This switch is not supported directly by C<Lingua::SoundChange>,
since it doesn't output anything either to a file or to the
screen (unless the C<printRules> option is specified); instead,
it returns the transformed words from C<change>.

=back

=head1 SEE ALSO

This module was inspired by Mark Rosenfelder's sound change applier,
documented at http://www.zompist.com/sounds.html , and by the sample
code he provides there. The interface is slightly similar.

=head1 AUTHOR

Philip Newton, E<lt>pne@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001 Philip Newton. Based on original code, copyright
(C) 2001 Mark Rosenfelder.

This software, along with its associated documentation and example
files, may be freely used, distributed, and modified, for non-commercial
purposes only, provided that the above copyright notice and this
permission notice are included in all copies or substantial
portions of the software.

To request a licence for commercial use of software based on Mark
Rosenfelder's sounds.c code, write to him at markrose@zompist.com.

=head2 NOTE

Please note the restriction on non-commercial use. Selling CPAN CDs,
for example, is fine as long as the cost is nominal, but using this
code to make money is not allowed.

This restriction may be removed in the future if the code is modified
so as not to be based on Mark's code any longer. (Most of it is
original anyway simply because

=over 4

=item *

Perl lends itself to a different approach than C, and

=item *

all the code for reading and parsing config files is basically not here.

=back

.)

=cut
