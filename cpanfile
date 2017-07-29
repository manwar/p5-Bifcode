#!perl
requires 'perl', '5.008001';
requires 'strict';
requires 'warnings';
requires 'utf8';
requires 'Carp';
requires 'Exporter::Tidy';
requires 'Unicode::UTF8';

on build => sub {
    requires 'ExtUtils::MakeMaker::CPANfile';
};

on test => sub {
    requires 'Test::Differences';
    requires 'Test::More', '0.88';
};

# vim: ft=perl
