use 5.010_001;
use strict;
use warnings;
use utf8;

# Le serveur de la coopérative a Perl 5.10.1 et rien d'autre : chaque module
# utilisé doit faire partie de la distribution de base de cette version.

use FindBin ();
use File::Find qw(find);
use File::Spec;
use Module::CoreList;
use Test::More;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my $VERSION_DU_SERVEUR = 5.010001;
my $racine = File::Spec->catdir($FindBin::Bin, File::Spec->updir);

my @fichiers = (File::Spec->catfile($racine, 'bin', 'passerelle'));
find(sub { push @fichiers, $File::Find::name if /\.(?:pm|pl|t)\z/ },
    map { File::Spec->catdir($racine, $_) } qw(lib outils t));

my %modules;
for my $fichier (@fichiers) {
    open my $fh, '<', $fichier or die "$fichier : $!";
    while (my $ligne = <$fh>) {
        last if $ligne =~ /\A__END__/;
        $modules{$1}{$fichier} = 1 if $ligne =~ /\A\s*(?:use|require)\s+([A-Za-z][\w:]*)/;
    }
    close $fh;
}

ok(scalar keys %modules > 10, 'les modules utilisés sont bien trouvés');
for my $module (sort keys %modules) {
    next if $module =~ /\APasserelle::/;
    my $depuis = Module::CoreList->first_release($module);
    ok(defined $depuis && $depuis <= $VERSION_DU_SERVEUR,
        sprintf '%s fait partie de Perl %s', $module, defined $depuis ? "depuis $depuis" : '(jamais)');
}

done_testing;
