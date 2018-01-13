#!/usr/bin/env perl

####################################################################################################
#                                                                                                  #
# braker.pl                                                                                        #
# Pipeline for predicting genes with GeneMark-ET and AUGUSTUS with RNA-Seq                         #
#                                                                                                  #
# Authors: Katharina Hoff, Simone Lange, Mario Stanke                                              #
#                                                                                                  #
# Contact: katharina.hoff@uni-greifswald.de                                                        #
#                                                                                                  #
# Release date: January 14th 2018                                                                  #
#                                                                                                  #
# This script is under the Artistic Licence                                                        #
# (http://www.opensource.org/licenses/artistic-license.php)                                        #
#                                                                                                  #
####################################################################################################

use Getopt::Long;
use File::Compare;
use File::Path qw(make_path rmtree);
use Module::Load::Conditional qw(can_load check_install requires);
use Scalar::Util::Numeric qw(isint);
use POSIX qw(floor);
use List::Util qw(min);
use Parallel::ForkManager;

use Cwd;
use Cwd 'abs_path';

use File::Spec::Functions qw(rel2abs);
use File::Basename qw(dirname basename);
use File::Copy;

BEGIN{
  $0 = rel2abs($0);
  our $directory = dirname($0);
} 
use lib $directory;
use helpMod qw(find checkFile formatDetector relToAbs setParInConfig uptodate);
use Term::ANSIColor qw(:constants);

use strict;
use warnings;


my $usage = <<'ENDUSAGE';

braker.pl     Pipeline for predicting genes with GeneMark-ET and AUGUSTUS with RNA-Seq

SYNOPSIS

braker.pl [OPTIONS] --genome=genome.fa --bam=rnaseq.bam


  --genome=genome.fa          fasta file with DNA sequences
  --bam=rnaseq.bam            bam file with spliced alignments from RNA-Seq


    
    
OPTIONS

    --help                               Print this help message
    --nice                               Execute all system calls within braker.pl and its submodules
                                         with bash "nice" (default nice value)
    --alternatives-from-evidence=true    Output alternative transcripts based on explicit evidence from 
                                         hints (default is true).
    --augustus-args="--some_arg=bla"     One or several command line arguments to be passed to AUGUSTUS,
                                         if several arguments are given, separated by whitespace, i.e.
                                         "--first_arg=sth --second_arg=sth". 
    --AUGUSTUS_CONFIG_PATH=/path/        Set path to config directory of AUGUSTUS (if not specified as 
                                         environment variable). BRAKER1 will assume that the directories
                                         ../bin and ../scripts of AUGUSTUS are located relative to
                                         the AUGUSTUS_CONFIG_PATH. If this is not the case, please
                                         specify AUGUSTUS_BIN_PATH (and AUGUSTUS_SCRIPTS_PATH if required).
                                         The Perl commandline argument --AUGUSTUS_CONFIG_PATH has higher
                                         priority than the environment variable with the same name.
    --AUGUSTUS_BIN_PATH=/path/           Set path to the AUGUSTUS directory that contains binaries, i.e.
    					 augustus and etraining. This variable must only be set if 
    					 AUGUSTUS_CONFIG_PATH does not have ../bin and ../scripts of
    					 AUGUSTUS relative to its location i.e. for global AUGUSTUS 
    					 installations. BRAKER1 will assume that the directory
    					 ../scripts of AUGUSTUS is located relative to the AUGUSTUS_BIN_PATH.
    					 If this is not the case, please specify AUGUSTUS_SCRIPTS_PATH.
    --AUGUSTUS_SCRIPTS_PATH=/path/       Set path to AUGUSTUS directory that contains scripts, i.e.
    				         splitMfasta.pl. This variable most only be set if
    				         AUGUSTUS_CONFIG_PATH or AUGUSTUS_BIN_PATH do not contains the
    				         ../scripts directory of AUGUSTUS relative to their location, i.e.
    				         for special cases of a global AUGUSTUS installation.
    --BAMTOOLS_PATH=/path/to/            Set path to bamtools (if not specified as environment 
      bamtools/                          variable). Has higher priority than the environment variable.
    --cores                              Specifies the maximum number of cores that can be used during 
                                         computation
    --extrinsicCfgFile=file              Optional. This file contains the list of used sources for the 
                                         hints and their boni and mali. If not specified the file "extrinsic.cfg" 
                                         in the config directory $AUGUSTUS_CONFIG_PATH is copied and adjusted.
    --fungus                             GeneMark-ET option: run algorithm with branch point model (most 
                                         useful for fungal genomes)
    --GENEMARK_PATH=/path/to/            Set path to GeneMark-ET/GeneMark-EP (if not specified as environment 
      gmes_petap.pl/                     variable). Has higher priority than environment variable.
    --gff3                               Output in GFF3 format.
    --hints=hints.gff                    Alternatively to calling braker.pl with a bam file, it is 
                                         possible to call it with a file that contains introns extracted 
                                         from RNA-Seq (or other data) in gff format. This flag also allows the usage
                                         of hints from additional extrinsic sources for gene prediction 
                                         with AUGUSTUS. To consider such additional extrinsic information,
                                         you need to use the flag --extrinsicCfgFile to specify parameters for 
                                         all sources in the hints file
                                         (including the source "E" for intron hints from RNA-Seq).
    --optCfgFile=ppx.cfg                 Optional custom config file for AUGUSTUS (see --hints).
    --overwrite                          Overwrite existing files (except for species parameter files)
    --SAMTOOLS_PATH=/path/to/            Optionally set path to samtools (if not specified as environment 
      samtools/                          variable) to fix BAM files automatically, if necessary. Has higher     
                                         priority than environment variable.
    --skipGeneMark-ET                    Skip GeneMark-ET and use provided GeneMark-ET output (e.g. from a
                                         different source) 
    --geneMarkGtf=file.gtf               If skipGeneMark-ET is used, braker will by default look in the 
                                         working directory in folder GeneMarkET for an already existing gtf
                                         file. Instead, you may provide such a file from another location.
                                         If geneMarkGtf option is set, skipGeneMark-ET is automatically also set.
    --skipOptimize                       Skip optimize parameter step (not recommended).
    --rounds                             the number of optimization rounds used in optimize_augustus.pl (default 5)
    --skipAllTraining                    Skip GeneMark-ET (training and prediction), skip AUGUSTUS training,
                                         only runs AUGUSTUS with pre-trained and already
                                         existing parameters (not recommended). Hints from input are still generated.
                                         This option automatically sets --useexisting to true.
    --softmasking                        Softmasking option for soft masked genome files. Set to 'on' or '1'
    --species=sname                      Species name. Existing species will not be overwritten. 
                                         Uses Sp_1 etc., if no species is assigned                          
    --useexisting                        Use the present config and parameter files if they exist for 
                                         'species'
    --workingdir=/path/to/wd/            Set path to working directory. In the working directory results
                                         and temporary files are stored
    --filterOutShort                     It may happen that a "good" training gene, i.e. one that has intron
                                         support from RNA-Seq in all introns predicted by GeneMark, is in fact
                                         too short. This flag will discard such genes that have supported introns
                                         and a neighboring RNA-Seq supported intron upstream of the start codon 
                                         within the range of the maximum CDS size of that gene and with a 
                                         multiplicity that is at least as high as 20% of the average intron 
                                         multiplicity of that gene.
    --crf                                Execute CRF training for AUGUSTUS; resulting parameters are only kept for
                                         final predictions if they show higher accuracy than HMM parameters.
    --prot_seq=prot.fa                   A protein sequence file in multiple fasta format. This file will be used
                                         to generate protein hints for AUGUSTUS by running one of the three
                                         alignment tools Exonerate (--prg=exonerate), Spaln (--prg=spaln) or 
                                         GenomeThreader (--prg=gth). Default is GenomeThreader if the tool is not 
                                         specified.
                                         Currently, hints from proteins are only used in the prediction step with
                                         AUGUSTUS. 
    --prot_aln=prot.aln                  Alignment file generated from aligning protein sequences against the 
                                         genome with either Exonerate (--prg=exonerate), or Spaln (--prg=spaln), or
                                         GenomeThreader (--prg=gth).
                                         To prepare alignment file, run Spaln2 with the following command:
                                            spaln -O0 ... > spalnfile
                                         To prepare alignment file, run Exonerate with the following command:
                                            exonerate --model protein2genome --showtargetgff T ... > exfile
                                         To prepare alignment file, run GenomeThreader with the following command:
                                            gth -genomic genome.fa  -protein protein.fa -gff3out -skipalignmentout 
                                               ... -o gthfile
                                         A valid option prg=... must be specified in combination with 
                                         --prot_aln. Generating tool will not be guessed.
                                         Currently, hints from proteins are only used in the prediction step with
                                         AUGUSTUS.
    --prg=gth|exonerate|spaln            Alignment tool gth (GenomeThreader), exonerate (Exonerate) or Spaln2
                                         (spaln) that will be used to generate protein alignments that will be the 
                                         basis for hints generation for gene prediction with AUGUSTUS (if specified
                                         in combination with --prot_seq) or that was used to externally
                                         generate an alignment file with the commands listed in description of 
                                         --prot_aln (if used in combination with --prot_aln).
    --ALIGNMENT_TOOL_PATH=/path/to/tool  Set path to alignment tool (GenomeThreader, Spaln, or Exonerate) if not 
                                         specified as environment variable. Has higher priority than environment
                                         variable.
    --version                            print version number of braker.pl

#### New command line arguments for utrrnaseq #####

    --UTR                                create UTR training examples from RNA-Seq coverage data; requires
                                         options --bam=rnaseq.bam and --softmasking. Alternatively, if UTR
                                         parameters already exist, training step will be skipped and those
                                         pre-existing parameters are used.
 
    --rnaseq2utr_args=params             expert option: pass additional parameters to rnaseq2utr as string

#### End of new command line arguments for utrrnaseq ####

#### New command line arguments for GeneMark-EP ####

# if no bam and no intron hints from b2h are given, braker.pl automatically goes into GeneMark-EP mode
# you can run braker.pl with GeneMark-EP using
# --genome=... --prot_seq=...
# --genome=... --prot_aln=...
# --genome=... --hints=...
# --GENEMARK_PATH=... must point at genemark executable location

    --skipGeneMark-EP                    Skip GeneMark-EP and use provided GeneMark-EP output (e.g. from a
                                         different source)

#### End of new command line arguments for GeneMark-EP ####
                           

DESCRIPTION
      
  Example:

    braker.pl [OPTIONS] --genome=genome.fa  --species=speciesname --bam=accepted_hits.bam
    braker.pl [OPTIONS] --genome.fa --species=speciesname --prot_seq=protein.fa
    braker.pl [OPTIONS] --genome.fa --species=speciesname --prot_aln=protein.aln
    braker.pl [OPTIONS] --genome.fa --species=speciesname --hints=hints.gff

ENDUSAGE

my $version = 2.1;                    # braker.pl version number
my $alternatives_from_evidence = "true"; # output alternative transcripts based on explicit evidence from hints
my $augpath;                          # path to augustus
my $augustus_cfg_path;                # augustus config path, higher priority than $AUGUSTUS_CONFIG_PATH on system
my $augustus_bin_path;                # path to augustus folder binaries folder
my $augustus_scripts_path;	      # path to augustus scripts folder
my $AUGUSTUS_CONFIG_PATH;
if(-e $ENV{'AUGUSTUS_CONFIG_PATH'}){
  $AUGUSTUS_CONFIG_PATH = $ENV{'AUGUSTUS_CONFIG_PATH'};
}
my $AUGUSTUS_BIN_PATH;
my $AUGUSTUS_SCRIPTS_PATH;
my @bam;                              # bam file names
my $bamtools_path;                    # path to bamtools executable, higher priority than $BAMTOOLS_BIN_PATH on system
my $BAMTOOLS_BIN_PATH = $ENV{'BAMTOOLS_PATH'}; # bamtools environment variable
my @bonus;                            # array of bonus values for extrinsic file
my $bool_species = "true";            # false, if $species contains forbidden words (e.g. chmod)
my $cmdString;                        # to store shell commands
my $CPU = 1;                          # number of CPUs that can be used
my $currentDir = cwd();               # working superdirectory where program is called from
my $errorfile;                        # stores current error file name
my $errorfilesDir;                    # directory for error files
my $extrinsicCfgFile;                 # assigned extrinsic file
my @files;                            # contains all files in $rootDir
my $flanking_DNA;                     # length of flanking DNA, default value is min{ave. gene length/2, 10000}
my @forbidden_words;                  # words/commands that are not allowed in species name (e.g. unlink)
my $fungus = 0;                       # option for GeneMark-ET
my $gb_good_size;                     # number of LOCUS entries in 'genbank.good.gb'                         
my $genbank;                          # genbank file name
my $genemarkDir;                      # directory for GeneMark-ET output
my $GENEMARK_PATH = $ENV{'GENEMARK_PATH'}; # path to 'gmes_petap.pl' script on system, environment variable
my $GMET_path;                        # GeneMark-ET path, higher priority than $GENEMARK_PATH; will use the same variable for GeneMark-EP path
my $genome;                           # name of sequence file
my $genome_length = 0;                # length of genome file
my $gff3 = 0;                         # create output file in GFF3 format
my $help;                             # print usage
my @hints;                            # input hints file names
my $hintsfile;                        # hints file (all hints)
my $prot_hintsfile;                   # hints file with protein hints
my $genemark_hintsfile;               # contains only intron hints in case $hintsfile also contains other hints types
my $limit = 10000000;                 # maximum for generic species Sp_$limit
my $logfile;                          # contains used shell commands
my @malus;                            # array of malus values for extrinsic file
my $optCfgFile;                       # optinonal extrinsic config file for AUGUSTUS
my $otherfilesDir;                    # directory for other files besides GeneMark-ET output and parameter files
my $overwrite = 0;                    # overwrite existing files (except for species parameter files)
my $parameterDir;                     # directory of parameter files for species
my $perlCmdString;                    # stores perl commands
my $printVersion = 0;                 # print version number, if set
my $SAMTOOLS_PATH = $ENV{'SAMTOOLS_PATH'}; # samtools environment variable
my $SAMTOOLS_PATH_OP;                 # path to samtools executable, higher priority than $SAMTOOLS_PATH on system
my $scriptPath=dirname($0);           # path of directory where this script is located
my $skipGeneMarkET = 0;               # skip GeneMark-ET and use provided GeneMark-ET output (e.g. from a different source)
my $skipGeneMarkEP = 0;               # skip GeneMark-EP and use provided GeneMark-EP output (e.g. from a different source)
my $skipoptimize = 0;                 # skip optimize parameter step
my $skipAllTraining = 0;              # skip all training (including no GeneMark-ET or GeneMark-EP run)
my $species;                          # species name
my $soft_mask = 0;                    # soft-masked flag
my $standard = 0;                     # index for standard malus/ bonus value (currently 0.1 and 1e1)optimize_augustus.pl
my $stdoutfile;                       # stores current standard output
my $string;                           # string for storing script path
my $augustus_args;                    # string that stores command line arguments to be passed to augustus
my $testsize;                         # AUGUSTUS training parameter: number of genes in a file that is
                                      # used to measure accuracy during parameter estimation with
                                      # optimize_augustus.pl. Default: 1000. If there are less than 1000
                                      # genes, all genes are used to measure accuracy. Decreasing this
                                      # parameter speeds up braker.pl but decreases prediction accuracy.
                                      # At least 300 genes are required for training AUGUSTUS.
my $useexisting = 0;                  # use existing species config and parameter files, no changes on those files
my $UTR = "off";                      # UTR prediction on/off. currently not available für new species 
my $workDir;                          # in the working directory results and temporary files are stored
my $filterOutShort;		      # filterOutShort option (see help)
# Hint type from input hintsfile will be checked; concers a) GeneMark-ET (requires
# intron hints) and b) writing of extrinsic.cfg from BRAKER2: other hint types will be set to neutral.
# If an extrinsic file is specified, this does not matter.
my @allowedHints = ("intron", "start", "stop", "ass", "dss", "exonpart", "exon", "CDSpart", "UTRpart", "nonexonpart");
my $crf;                              # flag that determines whether CRF training should be tried
my $nice;                             # flag that determines whether system calls should be executed with bash nice 
                                      #(default nice value)
my ($target_1, $target_2, $target_3) = 0; # variables that store AUGUSTUS accuracy after different training steps
my $prg;                              # variable to store protein alignment tool
my @prot_seq_files;                   # variable to store protein sequence file name
my @prot_aln_files;                   # variable to store protein alingment file name
my $ALIGNMENT_TOOL_PATH;              # stores path to binary of gth, spaln or exonerate for running protein alignments
my %hintTypes;                        # stores hint types occuring over all generated and supplied hints for comparison
my $rnaseq2utr_args;                # additional parameters to be passed to rnaseq2utr
my $rounds=5;                         # rounds used by optimize_augustus.pl
my $geneMarkGtf;                      # GeneMark output file (for skipGeneMark-ET option if not in braker working directory)
my $EPmode;                           # flag for executing GeneMark-EP instead of GeneMark-ET

############################################################
# Variables for modification of template extrinsic.cfg file
my @start_malus = (0.8, 0.8, 1);
my @start_p_bonus = ("1e3");
my $idx_start_p_malus = 0;
my $idx_start_p_bonus = 0;
my @stop_malus = (0.8, 0.8, 1);
my @stop_p_bonus = ("1e3");
my $idx_stop_p_malus = 0;
my $idx_stop_p_bonus = 0;
my @ass_malus = (0.1);
my $idx_ass_malus = 0;
my @ass_local_malus = (0.95);
my $idx_ass_local_malus = 0;
my @ass_p_bonus = (100);
my $idx_ass_p_bonus = 0;
my @dss_malus = (0.1);
my $idx_dss_malus = 0;
my @dss_local_malus = (0.95);
my $idx_dss_local_malus = 0;
my @dss_p_bonus = (100);
my $idx_dss_p_bonus = 0;
my @exonpart_local_malus = (0.992);
my $idx_exonpart_local_malus = 0;
my @exonpart_malus = (0.985);
my $idx_exonpart_malus = 0;
my @exonpart_w_bonus = (1.02);
my $idx_exonpart_w_bonus = 0;
my @exon_malus = (0);
my $idx_exon_malus = 0;
my @exon_p_bonus = (1);
my $idx_exon_p_bonus = 0;
my @intron_malus = (0.116);
my $idx_intron_malus = 0;
my @intron_e_bonus = ("1e6");
my $idx_intron_e_bonus = 0;
my @intron_p_bonus = ("1e6");
my $idx_intron_p_bonus = 0;
my @cdspart_malus = (0.985);
my $idx_cdspart_malus = 0;
my @cdspart_p_bonus = ("1e5");
my $idx_cdspart_p_bonus = 0;
my @utrpart_malus = (0.985);
my $idx_utrpart_malus = 0;
my @utrpart_w_bonus = ("1e5");
my $idx_utrpart_w_bonus = 0;
my $bam2wigPath; # make tool variable global
my $rnaseq2utrPath; # make tool variable global
#############################################################

# list of forbidden words for species name
@forbidden_words = ("system", "exec", "passthru", "run", "fork", "qx", "backticks", "chmod", "chown", "chroot", "unlink", "do", "eval", "kill", "rm", "mv", "grep", "cd", "top", "cp", "for", "done", "passwd", "while", "nice");  

# lists for extrinsic files
@bonus = ("1e1", "1e0", "1e2", "1e3", "1e4", "1e5");
@malus = ("0.1", "0.2", "0.4", "1.0"); 


if(@ARGV==0){
  print "$usage\n"; 
  exit(0);
}

GetOptions( 'alternatives-from-evidence=s'  => \$alternatives_from_evidence,
            'AUGUSTUS_CONFIG_PATH=s'        => \$augustus_cfg_path,
            'AUGUSTUS_BIN_PATH=s'           => \$augustus_bin_path,
            'AUGUSTUS_SCRIPTS_PATH=s'       => \$augustus_scripts_path,
	    'ALIGNMENT_TOOL_PATH=s'         => \$ALIGNMENT_TOOL_PATH,
            'bam=s'                         => \@bam,
            'BAMTOOLS_PATH=s'               => \$bamtools_path,
            'cores=i'                       => \$CPU,
            'fungus!'                       => \$fungus,
            'extrinsicCfgFile=s'            => \$extrinsicCfgFile,
            'GENEMARK_PATH=s'               => \$GMET_path,
            'genome=s'                      => \$genome,
            'gff3'                          => \$gff3,
            'hints=s'                       => \@hints,
            'optCfgFile=s'                  => \$optCfgFile,
            'overwrite!'                    => \$overwrite,
            'SAMTOOLS_PATH=s'               => \$SAMTOOLS_PATH_OP,
            'skipGeneMark-ET!'              => \$skipGeneMarkET,
            'skipGeneMark-EP!'              => \$skipGeneMarkEP,
            'skipOptimize!'                 => \$skipoptimize,
	    'skipAllTraining!'              => \$skipAllTraining,
            'species=s'                     => \$species,
            'softmasking!'                  => \$soft_mask,
            'testsize=i'                    => \$testsize,
            'useexisting!'                  => \$useexisting,
            'UTR=s'                         => \$UTR,
            'workingdir=s'                  => \$workDir,
	    'filterOutShort!'		    => \$filterOutShort,
	    'crf!'                          => \$crf,
	    'nice!'                         => \$nice,
            'help!'                         => \$help,
	    'prg=s'                         => \$prg,
	    'prot_seq=s'                    => \@prot_seq_files,
	    'prot_aln=s'                    => \@prot_aln_files,
	    'augustus_args=s'               => \$augustus_args,
	    'rnaseq2utr_args=s'             => \$rnaseq2utr_args,
	    'rounds=s'                      => \$rounds,
	    'geneMarkGtf=s'                 => \$geneMarkGtf,
            'version!'                      => \$printVersion);

if($help){
  print $usage;
  exit(0);
}

if($printVersion){
    print "braker.pl version $version\n";
    exit(0);
}

if($skipAllTraining){ # if no training is performed, existing parameters must be used
    $useexisting=1;
}

             ############ make some regular checks ##############

my $wdGiven; # defines whether a working directory was given as input argument
# if no working directory is set, use current directory
if(!defined $workDir){
  $workDir = $currentDir;
  $wdGiven=0;
}else{
    $wdGiven = 1;
    my $last_char = substr($workDir, -1);
    if($last_char eq "\/"){
	chop($workDir);
    }
    my $tmp_dir_name = abs_path($workDir);
    $workDir = $tmp_dir_name;
    if(not(-d $workDir)){
	print STDOUT "Creating directory $workDir.\n";
	mkdir $workDir;	
    }
}



# check the write permission of $workDir before building of the work directory
if(! -w $workDir){
  print STDERR "ERROR: Do not have write permission for $workDir.\nPlease use command 'chmod' to reset permissions, or specify another working directory with option --workingdir=...\n"; 
  exit(1);
}

# set path to augustus config folder
if(defined($augustus_cfg_path)){
  my $last_char = substr($augustus_cfg_path, -1);
  if($last_char eq "\/"){
    chop($augustus_cfg_path);
  }
  $AUGUSTUS_CONFIG_PATH = $augustus_cfg_path;
}

# check early on whether AUGUSTUS_CONFIG_PATH is writable
if(not(-w "$AUGUSTUS_CONFIG_PATH/species")){
    print STDERR "ERROR: AUGUSTUS_CONFIG_PATH/species (in this case $AUGUSTUS_CONFIG_PATH/species) is not writeable.\n";
    exit(1)
}

# set path to augustus folders
if(defined($augustus_bin_path)){
  my $last_char = substr($augustus_bin_path, -1);
  if($last_char eq "\/"){
    chop($augustus_bin_path);
  }
  $AUGUSTUS_BIN_PATH = $augustus_bin_path;
}else{
  $AUGUSTUS_BIN_PATH = "$AUGUSTUS_CONFIG_PATH/../bin";
}

if(defined($augustus_scripts_path)){
  my $last_char = substr($augustus_scripts_path, -1);
  if($last_char eq "\/"){
    chop($augustus_scripts_path);
  }
  $AUGUSTUS_SCRIPTS_PATH = $augustus_scripts_path;
}else{
  $AUGUSTUS_SCRIPTS_PATH = "$AUGUSTUS_BIN_PATH/../scripts";
}


# set path to GeneMark-ETs gmes_petap.pl script
if(defined($GMET_path)){
  my $last_char = substr($GMET_path, -1);
  if($last_char eq "\/"){
    chop($GMET_path);
  }
  $GENEMARK_PATH = $GMET_path;
}

# set path to bamtools
if(defined($bamtools_path)){
  my $last_char = substr($bamtools_path, -1);
  if($last_char eq "\/"){
    chop($bamtools_path);
  }
  $BAMTOOLS_BIN_PATH = $bamtools_path;
}

# set path to samtools (optional)
if(defined($SAMTOOLS_PATH_OP)){
  my $last_char = substr($SAMTOOLS_PATH_OP, -1);
  if($last_char eq "\/"){
    chop($SAMTOOLS_PATH_OP);
  }
  $SAMTOOLS_PATH = $SAMTOOLS_PATH_OP;
}

# set path to alignment tool (gth, spaln or exonerate, optional)
if(defined($ALIGNMENT_TOOL_PATH)){
    my $last_char = substr($ALIGNMENT_TOOL_PATH, -1);
    if($last_char eq "\/"){
	chop($ALIGNMENT_TOOL_PATH);
    }
}elsif($ENV{'ALIGNMENT_TOOL_PATH'} && @prot_seq_files){
    $ALIGNMENT_TOOL_PATH=$ENV{'ALIGNMENT_TOOL_PATH'};
}

# check upfront whether any common problems will occur later # see autoAug.pl
# print STDOUT "NEXT STEP: check files and settings\n"; 
check_upfront();
check_options();

# check whether hints files exists                                                                                                                                                                          
if(@hints){
    @hints = split(/[\s,]/, join(',',@hints));
    for(my $i=0; $i<scalar(@hints); $i++){
	if(! -e "$hints[$i]"){
	    print STDERR "ERROR: Hints file $hints[$i] does not exist.\n";
	    exit(1);
	}
	$hints[$i] = rel2abs($hints[$i]);
	check_gff($hints[$i]);
    }
}

# if hints files specified and no bam, check what sources and types of hints they contain -> this will determine whether braker.pl switches into EPmode
if(!@bam && @hints){
    my $foundRNASeq = 0;
    foreach(@hints){
	$foundRNASeq += checkHints($_);
    }
    if($foundRNASeq == 0){
	$EPmode = 1;
    }
}

# check whether RNA-Seq files are specified
if(!@bam && !@hints && $EPmode==0){
    print STDERR "ERROR: No RNA-Seq or hints file(s) from RNA-Seq specified. Please set at least one RNAseq BAM file or at least one hints file from RNA-Seq (must contain intron hints from src b2h in column 2) to run BRAKER in mode for training from RNA-Seq.\n$usage";
    exit(1);
}elsif((!@bam && !@hints && @prot_seq_files) || (!@bam && !@hints && @prot_aln_files)){
    $EPmode = 1;
}

if($EPmode==1){
    print STDOUT "BRAKER will be executed in GeneMark-EP mode, using protein information as sole extrinsic evidence source.\n";
}


# check whether bam files exist
if(@bam){
  @bam = split(/[\s,]/, join(',',@bam));
  for(my $i=0; $i<scalar(@bam); $i++){
    if(! -e $bam[$i]){
      print STDERR "ERROR: BAM file $bam[$i] does not exist.\n";
      exit(1);
    }
    $bam[$i] = rel2abs($bam[$i]);
  }
}

# check whether species is specified
if(defined($species)){
  if($species =~ /[\s]/){
    print STDOUT "WARNING: Species name contains invalid white space characters. Will replace white spaces with underline character '_'.\n";
    $species =~ s/\s/\_/g;
  }

  foreach my $word (@forbidden_words){
    if($species eq $word){
      print STDOUT "WARNING: $species is not allowed as a species name.\n";
      $bool_species = "false";
    }
  }
}

# use standard name when no name is assigned or when it contains invalid parts
if(!defined($species) || $bool_species eq "false"){
  my $no = 1;
  $species = "Sp_$no";
  while($no <= $limit){
    $species = "Sp_$no";
    if((! -d "$AUGUSTUS_CONFIG_PATH/species/$species")){
      last;
    }else{
      $no++;
    }
  }
  if($no > $limit){
    print STDERR "ERROR: There are already $limit species folders under $AUGUSTUS_CONFIG_PATH/species/ of type 'Sp_$limit'. Please delete or move some of those folders or assign a valid species identifier with --species=name.\n";
    exit(1);
  }
  if($bool_species eq "false"){
    print STDOUT "Program will use $species instead.\n";
  }else{
    print STDOUT "No species was set. Program will use $species.\n";
  }
}
    

# check species directory
if(-d "$AUGUSTUS_CONFIG_PATH/species/$species" && !$useexisting){
  print STDERR "ERROR: $AUGUSTUS_CONFIG_PATH/species/$species already exists. Choose another species name, delete this directory or use the existing species with the option --useexisting. Be aware that existing parameters will then be overwritten during training.\n";
  exit(1);
}

if(! -d "$AUGUSTUS_CONFIG_PATH/species/$species" && $useexisting){
  print STDOUT "WARNING: $AUGUSTUS_CONFIG_PATH/species/$species does not exist. Braker will create the necessary files for species $species.\n";
  $useexisting = 0;
}

# check whether $rootDir already exists
my $rootDir;
if($wdGiven==1){
    $rootDir = $workDir;
}else{
    $rootDir = "$workDir/braker";
}
if (-d "$rootDir/$species" && !$overwrite && $wdGiven==0){
    print STDOUT "WARNING: $rootDir/$species already exists. Braker will use existing files, if they are newer than the input files. You can choose another working directory with --workingdir=dir or overwrite it with --overwrite.\n";
}

# set path and check whether assigned extrinsic file exists
if(defined($extrinsicCfgFile)){
  $extrinsicCfgFile = rel2abs($extrinsicCfgFile);
}
if(defined($extrinsicCfgFile) && ! -f $extrinsicCfgFile){
  print STDOUT "WARNING: Assigned extrinsic file $extrinsicCfgFile does not exist. Program will create extrinsic file instead.\n";
  $extrinsicCfgFile = undef;
}

# check whether genome file is set
if(!defined($genome)){
  print STDERR "ERROR: No genome file was specified.\n";
  exit(1);
}

# check whether protein sequence file is given
if(@prot_seq_files){
    @prot_seq_files = split(/[\s,]/, join(',',@prot_seq_files));
    for(my $i=0; $i<scalar(@prot_seq_files); $i++){
	if(! -f $prot_seq_files[$i]){
	    print STDERR "ERROR: protein sequence file $prot_seq_files[$i] does not exist.\n";
	    exit(1);
	}
	$prot_seq_files[$i] = rel2abs($prot_seq_files[$i]);
    }
    if(!defined($prg) && $EPmode==0){
        # if no alignment tools was specified, set Genome Threader as default
	print STDOUT "WARNING: No alignment tool was specified for aligning protein sequences against genome. Setting GenomeThreader as default alignment tool.\n";
	$prg="gth";
    }elsif(!defined($prg) && $EPmode==1){
	$prg="prosplign";
	print STDOUT "WARNING: No alignment tool was specified for aligning protein sequences against genome. Setting ProSplign as default alignment tool for running BRAKER in GeneMark-EP mode.\n";
    }
}

# check whether protein alignment file is given
if(@prot_aln_files){
    @prot_aln_files = split(/[\s,]/, join(',',@prot_aln_files));
    for(my $i=0; $i<scalar(@prot_aln_files); $i++){
	if(! -f $prot_aln_files[$i]){
	    print STDERR "ERROR: protein alignment file $prot_aln_files[$i] does not exist.\n";
	    exit(1);
	}
	$prot_aln_files[$i] = rel2abs($prot_aln_files[$i]);
    }
    if(!defined($prg) && $EPmode==0){
	print STDERR "ERROR: if protein alignment file is specified, you must specify the source tool that was used to create that alignment file, i.e. --prg=gth for GenomeThreader, or --prg=spaln for Spaln2 or --prg=exonerate for Exonerate.\n";
	exit(1);
    }elsif(!defined($prg) && $EPmode==1){
	print STDOUT  "If protein alignment file is specified, you must specify the source tool that was used to create that alignment file, currently, --prg=prosplign is the only supported aligner for running BRAKER in GeneMark-EP mode. Setting \$prg to prosplign.\n";
        $prg="prosplign";
    }
}

# check whether alignment program is given
if(defined($prg)){
    if(not($prg=~m/gth/) and not($prg=~m/exonerate/) and not($prg=~m/spaln/) and $EPmode==0){
	print STDERR "ERROR: An alignment tool other than gth, exonerate and spaln has been specified with option --prg=$prg. BRAKER currently only supports the options gth, exonerate and spaln for running BRAKER in GeneMark-ET mode, and prosplign for running BRAKER in GeneMark-EP mode. BRAKER was now started in GeneMark-ET mode.\n";
	exit(1);
    }elsif(not($prg=~m/prosplign/) and $EPmode==1){
	print STDERR "ERROR: An alignment tool other than gth, exonerate and spaln has been specified with option --prg=$prg. BRAKER currently only supports the options gth, exonerate and spaln for running BRAKER in GeneMark-ET mode, and prosplign for running BRAKER in GeneMark-EP mode. BRAKER was now started in GeneMark-EP mode.\n";
        exit(1);
    }
    if(!@prot_seq_files and !@prot_aln_files){
	print STDERR "ERROR: a protein alignment tool ($prg) has been given, but neither a protein sequence file, nor a protein alignment file generated by such a tool have been specified.\n";
	exit(1);
    }
}


# check whether genome file exist
if(! -f "$genome"){
  print STDERR "ERROR: Genome file $genome does not exist.\n";
  exit(1);
}else{
    # create $rootDir
    my $bool_rootDir = "false";
    if(! -d $rootDir){
	make_path($rootDir);
	$bool_rootDir = "true";
    }
    # set other directories
    if($wdGiven==1){
	if($EPmode==0){
	    $genemarkDir = "$rootDir/GeneMark-ET";
	}else{
	    $genemarkDir = "$rootDir/GeneMark-EP";
	}
	$parameterDir = "$rootDir/species";
	$otherfilesDir = "$rootDir";
	$errorfilesDir = "$rootDir/errors";
    }else{
	if($EPmode==0){
	    $genemarkDir = "$rootDir/$species/GeneMark-ET";
	}else{
	    $genemarkDir = "$rootDir/$species/GeneMark-EP";
	}
	$parameterDir = "$rootDir/$species/species";
	$otherfilesDir = "$rootDir/$species";
	$errorfilesDir = "$rootDir/$species/errors";
    }

    $logfile = "$otherfilesDir/braker.log";
    # create other directories if necessary
    my $bool_otherDir = "false";
    if(! -d $otherfilesDir){
	make_path($otherfilesDir);
	$bool_otherDir = "true";
    }
    print STDOUT "Further logging information can be found in $logfile!\n";
    open (LOG, ">>".$logfile) or die("Cannot open file $logfile!\n");
    if($bool_rootDir eq "true"){
	print LOG "\# ".(localtime).": create working directory $rootDir.\n";
	print LOG "mkdir $rootDir\n\n";
    }
    if($bool_otherDir eq "true"){
	print LOG "\# ".(localtime).": create working directory $otherfilesDir.\n";
	print LOG "mkdir $otherfilesDir\n\n";
    }
    if(! -d $genemarkDir){
	make_path($genemarkDir);
	print LOG "\# ".(localtime).": create working directory $genemarkDir.\n";
	print LOG "mkdir $genemarkDir\n\n";
    }
    if(defined($geneMarkGtf) and not($skipGeneMarkET) && $EPmode==0){ # set skipGeneMarkET if geneMarkGtf is a command line argument
	$skipGeneMarkET=1;
    }elsif(defined($geneMarkGtf) and not($skipGeneMarkEP) && $EPmode==1){
	$skipGeneMarkET=1;
    }
  
    # check whether genemark.gtf file exists, if skipGeneMark-ET option is used
    if($skipGeneMarkET && $EPmode==0){ 
	print LOG "REMARK: The GeneMark-ET step will be skipped.\n";
	if(not(-f "$genemarkDir/genemark.gtf") and not(-f $geneMarkGtf)){
	    print STDERR "ERROR: The --skipGeneMark-ET option was used, but there is no genemark.gtf file under $genemarkDir and no valid file --geneMarkGtf=... was specified.\n";
	    if(defined($geneMarkGtf)){
		print STDERR "       The specified geneMarkGtf=... file was $geneMarkGtf. This is not an accessible file.\n";
	    }
	    exit(1);
	}
    }elsif($skipGeneMarkET){
	print STDERR "Option --skipGeneMarkET cannot be used when BRAKER is started in GeneMark-EP mode.\n";
	exit(1);
    }

    if($skipGeneMarkEP && $EPmode==1){
        print LOG "REMARK: The GeneMark-EP step will be skipped.\n";
        if(not(-f "$genemarkDir/genemark.gtf") and not(-f $geneMarkGtf)){
            print STDERR "ERROR: The --skipGeneMark-EP option was used, but there is no genemark.gtf file under $genemarkDir and no valid file --geneMarkGtf=... was specified.\n";
            if(defined($geneMarkGtf)){
                print STDERR "       The specified geneMarkGtf=... file was $geneMarkGtf. This is not an accessible file.\n";
            }
            exit(1);
        }
    }elsif($skipGeneMarkEP){
	print STDERR "Option --skipGeneMarkEP cannot be used when BRAKER is started in GeneMark-ET mode.\n";
	exit(1);
    }
    
    if(defined($geneMarkGtf)){
	print LOG "\#  ".(localtime).": creating softlink of $geneMarkGtf to $genemarkDir/genemark.gtf.\n";
	$cmdString = "ln -s $geneMarkGtf $genemarkDir/genemark.gtf";
	print LOG "$cmdString\n";
	system($cmdString)==0 or die("failed to execute: $cmdString!\n");
    }
    
    if(! -d $parameterDir){
	make_path($parameterDir);
	print LOG "\# ".(localtime).": create working directory $parameterDir\n";
	print LOG "mkdir $parameterDir\n\n";
    }

    if(! -d $errorfilesDir){
	make_path($errorfilesDir);
	print LOG "\# ".(localtime).": create working directory $errorfilesDir\n";
	print LOG "mkdir $errorfilesDir\n\n";
    }

    $genome = rel2abs($genome);
    $cmdString = "cd $rootDir;";
    print LOG "\# ".(localtime).": changing into working directory $rootDir\n";
    print LOG "$cmdString\n\n";
    chdir $rootDir or die ("Could not change into directory $rootDir.\n");

    if($skipAllTraining==0){
	new_species();  # create new species parameter files; we do this FIRST, before anything else, because if you start several processes in parallel, you might otherwise end up with those processes using the same species directory!
    }else{
	# if no training of AUGUSTUS will be executed, check whether species parameter files exist
	my $specPath = "$AUGUSTUS_CONFIG_PATH/species/$species/$species"."_";
	my @confFiles = ("exon_probs.pbl", "igenic_probs.pbl", "intron_probs.pbl", "metapars.cfg", "parameters.cfg", "weightmatrix.txt");
	foreach(@confFiles){
	    if(not(-e "$specPath"."$_")){
		print LOG "ERROR: Config file $specPath"."$_ for species $species does not exist!\n";
		print STDERR "Config file $specPath"."$_ for species $species does not exist!\n";
		exit(1);
	    }
	}
	if($UTR eq "on"){
	    @confFiles = ("metapars.utr.cfg", "utr_probs.pbl");
	    foreach(@confFiles){
		if(not(-e "$specPath"."$_")){
		    print LOG "ERROR: Config file $specPath"."$_ for species $species does not exist!\n";
		    print STDERR "Config file $specPath"."$_ for species $species does not exist!\n";
		    exit(1);
		}
	    }
	}
    }
    
    check_fasta_headers($genome); # check fasta headers
    if(@prot_seq_files){
	foreach(@prot_seq_files){
	    check_fasta_headers($_);
	}
    }
    # define $genemark_hintsfile: is needed because genemark can only handle intron hints, AUGUSTUS can also handle other hints types
    $genemark_hintsfile = "$otherfilesDir/genemark_hintsfile.gff";
    if($EPmode==0){
	make_rna_seq_hints();         # make hints from RNA-Seq
    }
    if(@prot_seq_files or @prot_aln_files){
	make_prot_hints(); # ALEX THIS FUNCTION CALLS GENERATION OF PROTEIN HINTS FROM ALIGNMENT OR SEQUENCE FILES
    }
    if(@hints){
	add_other_hints();
    }
    if(@prot_seq_files or @prot_aln_files or @hints){
	separateHints(); # GeneMark only takes intron hints, AUGUSTUS also takes other hints types
    }else{
	print LOG "\# ".(localtime).":  Creating softlink from $genemark_hintsfile to $hintsfile\n";
	$cmdString = "ln -s $hintsfile $genemark_hintsfile";
	print LOG "$cmdString\n";
	system($cmdString)==0 or die("failed to execute: $cmdString!\n");
    }

    if($skipAllTraining==0){
	if($EPmode==0){
	    GeneMark_ET();            # run GeneMark-ET
	    filterGeneMark();
	}elsif($EPmode==1){
	    GeneMark_EP();
	    filterGeneMark();
	}
	training();                   # train species-specific parameters with optimize_augustus.pl and etraining
    }
    
    # no extrinsic file is defined, extrinsic step is skipped or no file defined and softmasking option is used
    if(!defined($extrinsicCfgFile) || (!defined($extrinsicCfgFile) && $soft_mask)){
	extrinsic(); # use default extrinsic file
    }
    # copy extrinsic file to species parameters directory
    if(defined($extrinsicCfgFile) || (!defined($extrinsicCfgFile) && -e "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg") || (!defined($extrinsicCfgFile) && -e "$AUGUSTUS_BIN_PATH/../species/$species/extrinsic.$species.cfg")){
	# using cfg files from AUGUSTUS_CONFIG_PATH has higher priority than from AUGUSTUS_BIN_PATH
	if(!defined($extrinsicCfgFile) && -e "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg"){
	    $extrinsicCfgFile = "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg";
	}elsif(!defined($extrinsicCfgFile) && -e "$AUGUSTUS_BIN_PATH/../species/$species/extrinsic.$species.cfg"){
	    $extrinsicCfgFile = "$AUGUSTUS_BIN_PATH/../species/$species/extrinsic.$species.cfg";
	}
	@_ = split(/\//, $extrinsicCfgFile);
	if(!uptodate([$extrinsicCfgFile],["$parameterDir/$species/".$_[-1]])  || $overwrite){	
	    $cmdString = "";
	    if($nice){
		$cmdString .= "nice ";
	    }
	    if(not(-d "$parameterDir/$species/")){
		mkdir "$parameterDir/$species/";
	    }
	    $cmdString .= "cp $extrinsicCfgFile $parameterDir/$species/$_[-1]";
	    print LOG "\# ".(localtime).": copy extrinsic file to working directory\n";
	    print LOG "$cmdString\n\n";
	    system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	}
    }
    
    augustus("off"); # run augustus witout UTR
    if(!uptodate(["$otherfilesDir/augustus.gff"],["$otherfilesDir/augustus.aa"])  || $overwrite){
	getAnnoFasta("$otherfilesDir/augustus.gff"); # create protein sequence file
    }
    if(!uptodate(["$otherfilesDir/augustus.gff"],["$otherfilesDir/augustus.gtf"])  || $overwrite){
	make_gtf("$otherfilesDir/augustus.gff"); # convert output to gtf and gff3 (if desired) format
    }
    
    if($UTR eq "on"){
	train_utr();
    }

    clean_up(); # delete all empty files

    close(LOG) or die("Could not close log file $logfile!\n");
}



                           ############### sub functions ##############


         ####################### make hints #########################
# make hints from BAM files and optionally combine it with additional hints file
sub make_rna_seq_hints{
  my $bam_hints;
  my $hintsfile_temp = "$otherfilesDir/hintsfile.temp.gff";
  $hintsfile = "$otherfilesDir/hintsfile.gff";
  # from RNA-Seq data in bam format
  if(@bam){
    my $bam_temp = "$otherfilesDir/bam2hints.temp.gff";
    for(my $i=0; $i<scalar(@bam); $i++){
      $errorfile = "$errorfilesDir/bam2hints.$i.stderr";
      if(!uptodate([$bam[$i]],[$hintsfile])  || $overwrite){
        $bam[$i] = check_bam_headers($bam[$i]);
        if(-e "$AUGUSTUS_CONFIG_PATH/../bin/bam2hints"){
          $augpath = "$AUGUSTUS_CONFIG_PATH/../bin/bam2hints";
        }else{
          $augpath = "$AUGUSTUS_BIN_PATH/bin/bam2hints";
        }
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "$augpath --intronsonly --in=$bam[$i] --out=$bam_temp 2>$errorfile";
        print LOG "\# ".(localtime).": make hints from BAM file $bam[$i]\n";
        print LOG "$cmdString\n\n";
        system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
        $cmdString .= "cat $bam_temp >>$hintsfile_temp";
        print LOG "\n\# ".(localtime).": add hints from BAM file $bam[$i] to hints file\n";
        print LOG "$cmdString\n\n";
        system("$cmdString")==0 or die("failed to execute: $cmdString!\n");
      }
    }
    unlink($bam_temp);
  }
  if(-f $hintsfile_temp || $overwrite){
    if(!uptodate([$hintsfile_temp],[$hintsfile]) || $overwrite){
	join_mult_hints($hintsfile_temp, "rnaseq");
    }
    if(!uptodate([$hintsfile_temp],[$hintsfile]) || $overwrite){
      $string = find("filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
      $errorfile = "$errorfilesDir/filterIntronsFindStrand.stderr";
      $perlCmdString = "";
      if($nice){
	  $perlCmdString .= "nice ";
      }
      $perlCmdString .= "perl $string $genome $hintsfile_temp --score 1>$hintsfile 2>$errorfile";
      print LOG "\# ".(localtime).": filter introns, find strand and change score to \'mult\' entry\n";
      print LOG "$perlCmdString\n\n";
      system("$perlCmdString")==0 or die("failed to execute: $perlCmdString!\n");
      print LOG "\# ".(localtime).": rm $hintsfile_temp\n";
      unlink($hintsfile_temp);
    }
    if(-z $hintsfile){
	print LOG "\# ".(localtime)." ERROR: The hints file is empty. Maybe the genome and the RNA-seq file do not belong together.\n";
	print STDERR "ERROR: The hints file is empty. Maybe the genome and the RNA-seq file do not belong together.\n";
	exit(1);
    } 
  }
}

sub make_prot_hints{
    my $prot_hints;
    my $prot_hints_file_temp = "$otherfilesDir/prot_hintsfile.temp.gff";
    $prot_hintsfile = "$otherfilesDir/prot_hintsfile.gff";
    my $alignment_outfile = "$otherfilesDir/protein_alignment_$prg.gff3";   
    # change to working directory
    $cmdString = "cd $otherfilesDir";
    print LOG "\# ".(localtime).": Changing to $otherfilesDir\n";
    print LOG "$cmdString\n";
    chdir $otherfilesDir or die ("Failed to execute $cmdString!\n");
    # from fasta files
    if(@prot_seq_files && $EPmode==0){
	$string = find("startAlign.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	$errorfile = "$errorfilesDir/startAlign.stderr";
	$logfile = "$errorfilesDir/startAlign.stdout";
	for(my $i=0; $i<scalar(@prot_seq_files); $i++){
	    if(!uptodate([$prot_seq_files[$i]],[$prot_hintsfile])  || $overwrite){
		$perlCmdString = "";
		if($nice){
		    $perlCmdString .= "nice ";
		}
		$perlCmdString .= "perl $string --genome=$genome --prot=$prot_seq_files[$i] --ALIGNMENT_TOOL_PATH=$ALIGNMENT_TOOL_PATH ";
		if($prg eq "gth"){
		    $perlCmdString .= "--prg=gth ";
		    print LOG "\n\# ".(localtime).": running Genome Threader to produce protein to genome alignments\n";
		}elsif($prg eq "exonerate"){
		    $perlCmdString .= "--prg=exonerate ";
		    print LOG "\n\# ".(localtime).": running Exonerate to produce protein to genome alignments\n";
		}elsif($prg eq "spaln"){
		    $perlCmdString .= "--prg=spaln ";
		    print LOG "\n\# ".(localtime).": running Spaln to produce protein to genome alignments\n";
		}
		if($CPU>1){
		    $perlCmdString .= "--CPU=$CPU ";
		}
		if($nice){
		    $perlCmdString .= "--nice ";
		}
		$perlCmdString .= ">> $logfile 2>>$errorfile";
		print LOG "$perlCmdString\n\n";
		system("$perlCmdString")==0 or die ("failed to execute: $perlCmdString!\n");
		print LOG "\# ".(localtime).": Alignments from file $prot_seq_files[$i] created.\n";
		if(-s "$otherfilesDir/align_$prg/$prg.concat.aln"){
		    $cmdString = "cat $otherfilesDir/align_$prg/$prg.concat.aln >> $alignment_outfile";	    
		    print LOG "\# ".(localtime).": concatenating alignment file to $alignment_outfile\n";
		    print LOG "$cmdString\n\n";
		    system("$cmdString")==0 or die("Failed to execute $cmdString!\n");
		}else{
		    print LOG "\# ".(localtime).": alignment file $otherfilesDir/align_$prg/$prg.concat.aln in round $i was empty.\n";
		}
		print LOG "\n\# ".(localtime).": moving startAlign output files\n";
		$cmdString = "mv startAlign_$prg.log startAlign_$prg.log$i";
		print LOG "$cmdString\n";
		system("$cmdString")==0 or die("Failed to execute $cmdString!\n");
		$cmdString = "mv tmp_$prg tmp_$prg$i";
		print LOG "$cmdString\n";
		system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
		$cmdString = "mv align_$prg align_$prg$i";
		print LOG "$cmdString\n";
		system("$cmdString")==0 or die("Failed to execute: $cmdString!\n\n");	  
	    }else{
		print STDOUT "Skipping running alignment tool because files $prot_seq_files[$i] and $prot_hintsfile were up to date.\n";		
	    }  
	}
    }elsif(@prot_seq_files && $EPmode==0){
	# ALEX: INSERT CODE HERE TO GENERATE ALIGNMENTS WITH PROSPLIGN! YOU MAY ALTERNATIVELY CONSIDER PUTTING THIS INTO startAlign.pl BUT I ASSUME THAT YOU ALREADY HAVE YOUR OWN SCRIPT FOR THIS TASK
	# RESULT MUST BE AN ALIGNMENT FILE WITH ALL RELEVANT ALIGNMENTS FROM ALL INPUT FILES, I.E. BRAKER CAN TAKE MORE THAN ONE INPUT FILE, @prot_seq_files IS AN ARRAY WITH ALL THOSE FILES.
    }
    # convert pipeline created protein alignments to protein hints
    if(@prot_seq_files && -e $alignment_outfile){
	if(!uptodate([$alignment_outfile], [$prot_hintsfile]) || $overwrite){
	    if(-s $alignment_outfile && $EPmode==0){		
		aln2hints($alignment_outfile, $prot_hints_file_temp);
	    }elsif(-s $alignment_outfile && $EPmode==1){
		# ALEX: INSERT CODE HERE TO CONVERT PROSPLIGN ALIGNMENTS GENERATED BY BRAKER TO HINTS! YOU MAY ALTERNATIVELY CONSIDER PUTTING THIS into aln2hints FUNCTION IN braker.pl
	    }else{
		print LOG "\# ".(localtime).": Alignment out file $alignment_outfile with protein alignments is empty. Not producing any hints from protein input sequences.\n";
	    }
	}
    }
    # convert command line specified protein alignments to protein hints
    if(@prot_aln_files && $EPmode==0){
	for(my $i=0; $i<scalar(@prot_aln_files); $i++){
	    if(!uptodate([$prot_aln_files[$i]], [$prot_hintsfile]) || $overwrite){
		aln2hints($prot_aln_files[$i], $prot_hints_file_temp);
	    }else{
		print "Skipped converting alignment file $prot_aln_files[$i] to hints because it was up to date with $prot_hintsfile\n";
	    }
	}
    }elsif(@prot_aln_files && $EPmode==1){
	# ALEX: INSERT CODE HERE TO CONVERT COMMAND LINE ARGUMENT SUPPLIED PROSPLIGN ALIGNMENTS TO HINTS! @prot_aln IS AN ARRAY, I.E. THERE MAY BE MORE THAN ONE PROTEIN ALIGNMENT FILE. AGAIN: THIS COULD ALSO GO INTO THE aln2hints FUNCTION. 
    }
    # appending protein hints to $hintsfile (combined with RNA_Seq if available)
    if(-f $prot_hints_file_temp || $overwrite){
	if(!uptodate([$prot_hints_file_temp],[$prot_hintsfile])|| $overwrite){
	    join_mult_hints($prot_hints_file_temp, "prot");
	    print LOG "\# ".(localtime).": moving $prot_hints_file_temp to $prot_hintsfile\n";
	    $cmdString = "mv $prot_hints_file_temp $prot_hintsfile";
	    print LOG "$cmdString\n";
	    system($cmdString)==0 or die ("Failed to execute: $cmdString!\n");
	    print LOG "Deleting $prot_hints_file_temp\n";
	    unlink($prot_hints_file_temp);
	    print LOG "\n\# ".(localtime).": joining protein and RNA-Seq hints files -> appending $prot_hintsfile to $hintsfile\n";
	    $cmdString = "cat $prot_hintsfile >> $hintsfile";
	    print LOG "$cmdString\n";
	    system($cmdString)==0 or die ("Failed to execute: $cmdString!\n");
	    print LOG "\n\# ".(localtime).": Deleting $prot_hintsfile\n";
	    unlink($prot_hintsfile);
	    my $toBeSortedHintsFile = "$otherfilesDir/hintsfile.tmp.gff";
	    print LOG "\n\# ".(localtime).": Moving $hintsfile to $toBeSortedHintsFile to enable sorting\n";
	    $cmdString = "mv $hintsfile $toBeSortedHintsFile";
	    print LOG "$cmdString\n";
	    system($cmdString)==0 or die ("Failed to execute: $cmdString!\n");
	    print LOG "\n\# ".(localtime).": Sorting hints file $hintsfile\n";
	    $cmdString = "cat $toBeSortedHintsFile | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 > $hintsfile";
	    print LOG "$cmdString\n";
	    system($cmdString)==0 or die("Failed to execute: $cmdString!\n");
	    print LOG "\n\# ".(localtime).": Deleting file $toBeSortedHintsFile\nrm $toBeSortedHintsFile\n";
	    unlink($toBeSortedHintsFile);
	}
    }
    if(-z $prot_hintsfile){
	print LOG "\n\# ".(localtime)." ERROR: The hints file is empty. There were no protein alignments.\n";
	print STDERR "ERROR: The hints file is empty. There were no protein alignments.\n";
	exit(1);
    }
}

# adding externally created hints
sub add_other_hints{
    if(@hints){
	# have "uptodate" issues at this point, removed it... maybe fix later
	for(my $i=0; $i<scalar(@hints); $i++){
	    $cmdString = "";
	    if($nice){
		$cmdString .= "nice ";
	    }
	    $cmdString .= "cat $hints[$i] >> $hintsfile";
	    print LOG "\n\# ".(localtime).": adding hints from file $hints[$i] to $hintsfile\n";
	    print LOG "$cmdString\n\n";
	    system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	}
	join_mult_hints($hintsfile, "all");
    }
}

# checks which hint types are present in the hintsfile that will be used for running AUGUSTUS
sub identifyHintTypes{
    open(HINTS, "<", $hintsfile) or die ("Could not open hints file $hintsfile!\n");
    while(<HINTS>){
	$_=~m/src=(\w)/;
	if(not(defined($hintTypes{$1}))){
	    $hintTypes{$1} = 1;
	}
    }
    close(HINTS) or die ("Could not close hints file $hintsfile!\n");
}

# checks whether hints files contain RNA-Seq or protein hints; if file does contain RNA-Seq, it returns 1, otherwise 0.
sub checkHints{
    my $thisHintsFile = shift;
    my @areb2h = `cut -f 2 $thisHintsFile | grep b2h`;
    my $ret = 0;
    if(scalar(@areb2h>0)){
	$ret = 1;
    }
    return $ret;
}

# split into two hints files: one for GeneMark with intron hints, only, and one for AUGUSTUS with all hints
sub separateHints{
    # Find out whether $hintsfile contains anything but intron hints
    print LOG "\n\# ".(localtime).": Checking whether $hintsfile contains hints other than intron\n";
    print LOG "cut -f 3 $hintsfile | grep -m 1 -v intron\n";
    my @notIntron = `cut -f 3 $hintsfile | grep -m 1 -v intron`;
    if(not(scalar(@notIntron)==0)){
	print LOG "\n\# ".(localtime).":  Hint types other than intron are contained in $hintsfile\nExtracting intron hints for GeneMark.\n";
	if($EPmode==0){
	    $cmdString = "grep intron $hintsfile | grep b2h > $genemark_hintsfile"; # if ET mode, take only RNA-Seq introns, src b2h
	}else{
	    $cmdString = "grep intron $hintsfile > $genemark_hintsfile"; # if in EP mode, take ALL intron hints (because they are all from protein source)
	}
	print LOG "$cmdString\n\n";
	system($cmdString)==0 or die("Failed to execute: $cmdString\n");
    }else{
	print LOG "\n\# ".(localtime).":  No other hint types found. Creating softlink from $genemark_hintsfile to $hintsfile\n";
	$cmdString = "ln -s $hintsfile $genemark_hintsfile";
	print LOG "$cmdString\n";
	system($cmdString)==0 or die("Failed to execute: $cmdString\n");
    }
}



sub aln2hints{
    my $aln_file = shift;
    if(! (-z $aln_file)){
	my $out_file_name = "$otherfilesDir/prot_hintsfile.aln2hints.temp.gff";
	my $final_out_file = shift;
	print LOG "\n\# ".(localtime).": Converting protein alignment file $aln_file to hints for AUGUSTUS\n";
	$perlCmdString = "perl ";
	if($nice){
	    $perlCmdString .= "nice ";
	}
	$string = find("align2hints.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	$perlCmdString .= "$string --in=$aln_file --out=$out_file_name ";
	if($prg eq "spaln"){
	    $perlCmdString .= "--prg=spaln";
	}elsif($prg eq "gth"){
	    $perlCmdString .= "--prg=gth";
	}elsif($prg eq "exonerate"){
	    $perlCmdString .= "--prg=exonerate --genome_file=$genome";
	}
	print LOG "$perlCmdString\n";
	system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString\n");
	$cmdString = "cat $out_file_name >> $final_out_file";
	print LOG "\n\# ".(localtime).": concatenating protein hints from $out_file_name to $final_out_file\n";
	print LOG $cmdString."\n";
	system("$cmdString")==0 or die ("Failed to execute: $cmdString\n");
    }else{
	print "Alignment file $aln_file was empty!\n";
	print LOG "\# ".(localtime).": Alignment file $aln_file was empty!\n";
    }
}

sub join_mult_hints{
    my $hints_file_temp = shift;
    my $type = shift; # rnaseq or prot or whatever will follow
    my $hintsfile_temp_sort = "$otherfilesDir/hints.$type.temp.sort.gff";
    $cmdString = "";
    if($nice){
	$cmdString .= "nice ";
    }
    $cmdString .= "cat $hints_file_temp | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 >$hintsfile_temp_sort";
    print LOG "\n\# ".(localtime).": sort hints of type $type\n";
    print LOG "$cmdString\n\n";
    system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
    $string = find("join_mult_hints.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    $errorfile = "$errorfilesDir/join_mult_hints.$type.stderr";
    $perlCmdString = "";
    if($nice){
	$perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string <$hintsfile_temp_sort >$hints_file_temp 2>$errorfile";
    print LOG "\# ".(localtime).": join multiple hints\n";
    print LOG "$perlCmdString\n\n";
    system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
    unlink($hintsfile_temp_sort);
}
    



         ####################### GeneMark-ET #########################
# start GeneMark-ET and convert its output to real gtf format
sub GeneMark_ET{
    if(!$skipGeneMarkET){
	if(!uptodate([$genome,$genemark_hintsfile],["$genemarkDir/genemark.gtf"])  || $overwrite){
	    $cmdString = "cd $genemarkDir";
	    print LOG "\n\# ".(localtime).": changing into GeneMark-ET directory $genemarkDir\n";
	    print LOG "$cmdString\n\n";
	    chdir $genemarkDir or die ("Could not change into directory $genemarkDir.\n");
	    $string = "$GENEMARK_PATH/gmes_petap.pl";
	    $errorfile = "$errorfilesDir/GeneMark-ET.stderr";
	    $stdoutfile = "$otherfilesDir/GeneMark-ET.stdout";
	    $perlCmdString = "";
	    if($nice){
		$perlCmdString .= "nice ";
	    }
	    $perlCmdString .= "perl $string --verbose --sequence=$genome --ET=$genemark_hintsfile --cores=$CPU"; # consider removing --verbose, later
	    if($fungus){
		$perlCmdString .= " --fungus";
	    }
	    if($soft_mask){
		#  $perlCmdString .= " --soft_mask"; # version prior to 4.29
		$perlCmdString .= " --soft 1000"; # version 4.29
	    }
	    $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
	    print LOG "\# ".(localtime).": Running GeneMark-ET\n";
	    print LOG "$perlCmdString\n\n";
	    system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
	    $cmdString = "cd $rootDir";
	    print LOG "\# ".(localtime).": change to working directory $rootDir\n";
	    print LOG "$cmdString\n\n";
	    chdir $rootDir or die ("Could not change to directory $rootDir.\n");
	}
    }
}

sub GeneMark_EP{
    if(!$skipGeneMarkEP){
	if(!uptodate([$genome,$genemark_hintsfile],["$genemarkDir/genemark.gtf"])  || $overwrite){
	    $cmdString = "cd $genemarkDir";
	    print LOG "\n\# ".(localtime).": changing into GeneMark-EP directory $genemarkDir\n";
	    print LOG "$cmdString\n\n";
	    chdir $genemarkDir or die ("Could not change into directory $genemarkDir.\n");
	    $string = "$GENEMARK_PATH/gmes_petap.pl"; # ALEX: IS THIS THE CORRECT SCRIPT TO RUN GENEMARK-EP?
	    $errorfile = "$errorfilesDir/GeneMark-EP.stderr";
	    $stdoutfile = "$otherfilesDir/GeneMark-EP.stdout";
	    $perlCmdString = "";
	    if($nice){
		$perlCmdString .= "nice ";
	    }
	    $perlCmdString .= "perl $string --verbose --sequence=$genome --EP=$genemark_hintsfile --cores=$CPU"; # ALEX: IS THIS THE CORRECT CALL FOR GENEMARK-EP?
	    if($fungus){
		$perlCmdString .= " --fungus";
	    }
	    if($soft_mask){
		$perlCmdString .= " --soft 1000"; # ALEX: DOES THIS MAKE SENSE FOR CALLING GENEMARK-EP?
	    }
	    $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
	    print LOG "\# ".(localtime).": Running GeneMark-EP\n";
	    print LOG "$perlCmdString\n\n";
	    system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
	    $cmdString = "cd $rootDir";
	    print LOG "\# ".(localtime).": change to working directory $rootDir\n";
	    print LOG "$cmdString\n\n";
	    chdir $rootDir or die ("Could not change to directory $rootDir.\n");
	}
	# ALEX: IT IS IMPORTANT THAT A FILE $genemarkDir/genemark.gtf WILL BE GENERATED BY THE GENEMARK-EP RUN
    }
}

sub filterGeneMark{
    # convert GeneMark output to gtf format with doublequotes (for older GeneMark versions) and filter genes for training
    if(!uptodate(["$genemarkDir/genemark.gtf", $hintsfile],["$genemarkDir/genemark.c.gtf","$genemarkDir/genemark.f.good.gtf", "$genemarkDir/genemark.average_gene_length.out"])  || $overwrite){
	print LOG "\# ".(localtime).": converting GeneMark output to gtf format\n"; 
	$string=find("filterGenemark.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	$errorfile = "$errorfilesDir/filterGenemark.stderr";
	$stdoutfile = "$otherfilesDir/filterGenemark.stdout";
	$perlCmdString = "";
	if($nice){
	    $perlCmdString .= "nice ";
	}
	if(!$filterOutShort){
	    $perlCmdString .= "perl $string --genemark=$genemarkDir/genemark.gtf --introns=$hintsfile 1>$stdoutfile 2>$errorfile";
	}else{
	    print LOG "\# ".(localtime).": Option activated: Filtering out training genes from GeneMark that are too short (upstream intron)\n";
	    $perlCmdString .= "perl $string --genemark=$genemarkDir/genemark.gtf --introns=$hintsfile --filterOutShort 1>$stdoutfile 2>$errorfile";
	}
	print LOG "$perlCmdString\n\n";
	system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
    }
}



         ####################### create a new species #########################
# create a new species $species and extrinsic file from generic one 
sub new_species{
  $augpath = "$AUGUSTUS_CONFIG_PATH/species/$species";
  if((!uptodate([$augpath."/$species\_metapars.cfg"],[$augpath."/$species\_parameters.cfg", $augpath."/$species\_exon_probs.pbl"]) && !$useexisting) || ! -d "$AUGUSTUS_CONFIG_PATH/species/$species"){
      if(-d "$AUGUSTUS_CONFIG_PATH/species"){
	  if(-w "$AUGUSTUS_CONFIG_PATH/species"){
	      $string=find("new_species.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	      $errorfile = "$errorfilesDir/new_species.stderr";
	      $perlCmdString = "";
	      if($nice){
		  $perlCmdString .= "nice ";
	      }
	      $perlCmdString .= "perl $string --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH 1> /dev/null 2>$errorfile";
	      print LOG "\# ".(localtime).": create new species $species in $AUGUSTUS_CONFIG_PATH/species\n";
	      print LOG "$perlCmdString\n\n";
	      system("$perlCmdString")==0 or die("Failed to create new species with new_species.pl, check write permissions in $AUGUSTUS_CONFIG_PATH/species directory! Command was $perlCmdString\n");
	  }else{
	      print STDERR "Directory $AUGUSTUS_CONFIG_PATH/species is not writable! You must make the directory AUGUSTUS_CONFIG_PATH/species writable or specify another AUGUSTUS_CONFIG_PATH!\n";
	  }
      }else{
	  print STDERR "Directory $AUGUSTUS_CONFIG_PATH/species does not exist. Please check that AUGUSTUS_CONFIG_PATH is set, correctly!\n";
      }
  }
}


# create default extrinsic file (without BLAST)

sub extrinsic{
    my $extrinsic;
    my $string = find("extrinsic.M.RM.E.W.P.cfg", $AUGUSTUS_BIN_PATH, "$AUGUSTUS_CONFIG_PATH/extrinsic" , $AUGUSTUS_CONFIG_PATH);
    if(-e $string){
	$extrinsic = $string;
	print LOG "\# ".(localtime).": Will use $string as template for this project's extrinsic.cfg\n";
    }else{
	print LOG "\# ".(localtime)." ERROR: Cannot find extrinsic template file extrinsic.M.RM.E.W.P.cfg in BRAKER2 directory or $AUGUSTUS_CONFIG_PATH/extrinsic/extrinsic.M.RM.E.W.P.cfg.\n";
	die "Cannot find extrinsic template file extrinsic.M.RM.E.W.P.cfg in BRAKER2 directory or $AUGUSTUS_CONFIG_PATH/extrinsic/extrinsic.M.RM.E.W.P.cfg.\n";
    }
    my $extrinsic_cp = "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg";
    if(!defined($extrinsicCfgFile) || (defined($extrinsicCfgFile) && ! -e $extrinsicCfgFile) ){
	if(!defined($extrinsicCfgFile)){
	    print LOG "\# ".(localtime).": No extrinsic file assigned. Program will create one.\n";
	    identifyHintTypes(); # checks which hint types occur in the hintsfile for AUGUSTUS $hintsfile, stores in %hintTypes
	}
	if(! -e $extrinsic_cp){
	    # braker.pl heavily depends on the correct format of the template extrinsic.cfg file (e.g. order of columns,
	    # number of bonus per source, etc.
	    print LOG "\# ".(localtime).": create extrinsic file\n";
	    open (EXTRINSIC, "<", $extrinsic) or die ("Cannot open file: $extrinsic!\n");
	    open (OUT, ">", $extrinsic_cp) or die ("Cannot open file: $extrinsic_cp!\n");
	    my $GENERAL = "false";
	    my $bonus_idx = $standard; # 0 => 1e1  (currently standard)
	    my $malus_idx = $standard; # 0 => 0.1  (currently standard)
	    my $sourcesSeen = 0;
	    while(<EXTRINSIC>){
		if(($_=~m/^\#/) or ($_=~m/^\n$/)){
		    print OUT $_;
		}elsif($_=~m/^\[SOURCES\]/){
		    $sourcesSeen = 1;
		    print OUT $_;
		}elsif($sourcesSeen==1){
		    chomp;
		    # checking whether all hint types (e.g. E, W, P) that are present in the hints file to be used are also present in the config template file. Currently, braker.pl supports hints of type E, W, and P (and M). 
		    my @typesInCfg = split(" ", $_);
		    my %typesInCfgHash;
		    foreach(@typesInCfg){
			chomp;
			if(not(defined($typesInCfgHash{$_}))){
			    $typesInCfgHash{$_} = 1;
			}
		    }
		    foreach my $key (keys(%hintTypes)) {
			if(not(defined($typesInCfgHash{$key}))){
			    print LOG "\# ".(localtime)." ERROR: Hints file contains hints from type $key. BRAKER is currently not able to print an extrinsic.cfg file for this hint type. Please run braker.pl with flag --extrinsicCfgFile=customExtrinsicFile.cfg where customExtrinsicFile.cfg is a file tailored to your hint types. Aborting program.\n";
			    print STDERR "Hints file contains hints from type $key. BRAKER is currently not able to print an extrinsic.cfg file for this hint type. Please run braker.pl with flag --extrinsicCfgFile=customExtrinsicFile.cfg where customExtrinsicFile.cfg is a file tailored to your hint types. Aborting program.\n";
			    exit(1);
			}
			
		    }
		    $sourcesSeen=0;
		    print OUT $_."\n";
		}elsif(($_=~m/^\[SOURCE-PARAMETERS\]/)or($_ =~ m/^\[GENERAL\]/)){
		    print OUT $_;
		}else{ # actual parameter lines
		    $_ =~ s/^\s+//; # remove whitespace before first field
		    my @line = split(/\s+/, $_);
		    # check whether order and number of columns in template extrinsic file are compatible with braker.pl of this version
		    if(scalar(@line)==18){ # no local malus present
			if(not(($line[3]=~m/^M$/) and ($line[6]=~m/RM/) and ($line[9]=~m/E/) and ($line[12]=~m/W/) and ($line[15]=~m/P/))){
			    print LOG "\# ".(localtime)." ERROR: In extrinsic template file $extrinsic, column 4 does not contain M, and/or column 7 does not contain RM, and/or column 11 does not contain E and/or column 13 does not contain W and/or column 16 does not contain P. Aborting braker! (line without local malus)\n";
			    print STDERR "In extrinsic template file $extrinsic, column 4 does not contain M, and/or column 7 does not contain RM, and/or column 11 does not contain E and/or column 13 does not contain W and/or column 16 does not contain P. Aborting braker! (line without local malus)\n";
			    exit(1);
			}
		    }else{ # local malus present, 19 columns
			if(not(($line[4]=~m/^M$/) and ($line[7]=~m/RM/) and ($line[10]=~m/E/) and ($line[13]=~m/W/) and ($line[16]=~m/P/))){
			    print LOG "\# ".(localtime)." ERROR:In extrinsic template file $extrinsic, column 5 does not contain M, and/or column 8 does not contain RM, and/or column 111 does not contain E and/or column 14 does not contain W and/or column 17 does not contain P. Aborting braker! (line with local malus)\n"; 
			    print STDERR "In extrinsic template file $extrinsic, column 5 does not contain M, and/or column 8 does not contain RM, and/or column 111 does not contain E and/or column 14 does not contain W and/or column 17 does not contain P. Aborting braker! (line with local malus)\n";
			    exit(1);
			}
		    }
		    # print template based parameter lines depending on combination of input hint types
		    if($line[0] =~ m/start/){
			if(defined($hintTypes{P})){ # protein hints
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($start_malus[$idx_start_p_malus],12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($start_p_bonus[$idx_start_p_bonus],8);
			    print OUT "\n";
			}else{ # no protein hints
                            print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/stop/){
			if(defined($hintTypes{P})){ # protein hints
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($stop_malus[$idx_stop_p_malus],12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($stop_p_bonus[$idx_stop_p_bonus],8);
			    print OUT "\n";
			}else{ # no protein hints
                            print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/ass/){
			if(defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($ass_local_malus[$idx_ass_local_malus],6).printCfg($ass_malus[$idx_ass_malus], 6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($ass_p_bonus[$idx_ass_p_bonus],8);
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,6).printCfg(1,6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/dss/){
			if(defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($dss_local_malus[$idx_dss_local_malus],6).printCfg($dss_malus[$idx_dss_malus],6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($dss_p_bonus[$idx_dss_p_bonus],8);
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,6).printCfg(1,6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
                        }
		    }elsif($line[0]=~m/^exonpart$/){
			if(defined($hintTypes{W})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($exonpart_local_malus[$idx_exonpart_local_malus],6).printCfg($exonpart_malus[$idx_exonpart_malus],6);
			    for (my $i=4; $i <= 14; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($exonpart_w_bonus[$idx_exonpart_w_bonus],8);
			    for (my $i=16; $i <= 18; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,6).printCfg(1,6);
			    for (my $i=4; $i <= 14; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    for (my $i=16; $i <= 18; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/^exon$/){
			if(defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($exon_malus[$idx_exon_malus],12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($exon_p_bonus[$idx_exon_p_bonus],8);
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg(1,12);
			    for (my $i=3; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/^intron$/){
			if(defined($hintTypes{E}) && defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($intron_malus[$idx_intron_malus],12);
			    for (my $i=3; $i <= 10; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($intron_e_bonus[$idx_intron_e_bonus],8);
			    for (my $i=12; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($intron_p_bonus[$idx_intron_p_bonus],8);
			    print OUT "\n";
			}elsif(defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($intron_malus[$idx_intron_malus],12);
			    for (my $i=3; $i <= 10; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    for (my $i=12; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($intron_p_bonus[$idx_intron_p_bonus],8);
			    print OUT "\n";
			}else{ # only hintTypes{E}
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($intron_malus[$idx_intron_malus],12);
			    for (my $i=3; $i <= 10; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($intron_e_bonus[$idx_intron_e_bonus],8);
			    for (my $i=12; $i <= 16; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/CDSpart/){
			if(defined($hintTypes{P})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],6).printCfg($cdspart_malus[$idx_cdspart_malus],6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($cdspart_p_bonus[$idx_cdspart_p_bonus],8);
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],6).printCfg(1,6);
			    for (my $i=4; $i <= 17; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    print OUT "\n";
			}
		    }elsif($line[0]=~m/UTRpart/){
			if(defined($hintTypes{W})){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],6).printCfg($utrpart_malus[$idx_utrpart_malus],6);
			    for (my $i=4; $i <= 14; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg($utrpart_w_bonus[$idx_utrpart_w_bonus],8);
			    for (my $i=16; $i <= 18; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT "\n";
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],6).printCfg(1,6);
			    for (my $i=4; $i <= 14; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT printCfg(1,8);
			    for (my $i=16; $i <= 18; $i++){
				print OUT printCfg($line[$i], 8);
			    }
			    print OUT "\n";
			}
		    }else{
			if(scalar(@line)==18){
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],12);
			}else{
			    print OUT printCfg($line[0], 11).printCfg($line[1], 7).printCfg($line[2],6).printCfg($line[3],6);
			}
			my $from;
			if(scalar(@line)==18){
			    $from = 3;
			}else{
			    $from = 4;
			}
			for (my $i=$from; $i <= ($from+14); $i++){
			    print OUT printCfg($line[$i], 8);
			}
			print OUT "\n";
		    }
		}   
	    }
	    close(OUT) or die("Could not close extrinsic file $extrinsic_cp!\n");
	    close(EXTRINSIC) or die("Could not close extrinsic file $extrinsic!\n");
	    $extrinsicCfgFile = $extrinsic_cp;
	}else{
	    $extrinsicCfgFile = $extrinsic_cp;
	    print LOG "\# ".(localtime).": Found extrinsic.cfg $extrinsic_cp, will use this file!\n";
	}
    }else{	    
	print LOG "\# ".(localtime).": No extrinsic file was created. Program uses assigned extrinsic file: $extrinsicCfgFile\n";
    }
}

# subroutine for printing extrinsic.cfg pretty
sub printCfg{
    my $field = shift;
    my $length = shift;
    my $nSpaces = $length - length($field);
    if($nSpaces < 0){
	print LOG "\# ".(localtime)." WARNING: Format error in extrinsic.cfg file. File will still be functional, but may look messy to human reader!\n";
	$nSpaces = 1;
    }
    my $returnString = " " x $nSpaces;
    $returnString .= $field;
    return $returnString;
}


         ####################### train AUGUSTUS #########################
# create genbank file and train AUGUSTUS parameters for given species
sub training{
    # get average gene length for flanking region
     print LOG "\# ".(localtime).": Computing flanking DNA size\n"; 
     # compute average gene length from genemark.gtf                                                       
     open (GENELENGTH, "<$genemarkDir/genemark.average_gene_length.out") or die "Cannot open file: $genemarkDir/genemark.average_gene_length.out\n";
     @_ = split(/\t/,<GENELENGTH>);
     my $average_length = $_[0];
     close(GENELENGTH) or die("Could not close file $genemarkDir/genemark.average_gene_length.out!\n");
     if($average_length < 0){
	 print LOG "\# ".(localtime)." ERROR: Average gene length of genes predicted by GeneMark-ET is negative. This indicates GeneMark-ET did not finish, properly. Please delete the GeneMark-ET folder and restart BRAKER1!\n";
        die("Average gene length of genes predicted by GeneMark-ET is negative. This indicates GeneMark-ET did not finish, properly. Please delete the GeneMark-ET folder and restart BRAKER1!\n");
    }
     $flanking_DNA = min((floor($average_length/2), 10000));
     if($flanking_DNA < 0){
	 print LOG "\# ".(localtime)." WARNING: \$flanking_DNA has the value $flanking_DNA , which is smaller than 0. Something must have gone wrong, there. Replacing by value 500.\n"; # added by Katharina Hoff
	 $flanking_DNA = 500;
     }
     # create genbank file from fasta input and GeneMark-ET output
     $string = find("gff2gbSmallDNA.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
     $genbank = "$otherfilesDir/genbank.gb";
     if(!uptodate([$genome,"$genemarkDir/genemark.c.gtf"],[$genbank])  || $overwrite){
	 $errorfile = "$errorfilesDir/gff2gbSmallDNA.stderr";
	 if(-z "$genemarkDir/genemark.c.gtf"){
	     print LOG  "\# ".(localtime)." ERROR: The GeneMark-ET output file is empty!\n";
	     print STDERR "ERROR: The GeneMark-ET output file is empty!\n";
	     exit(1);
	 }
	 $perlCmdString = "";
	 if($nice){
	     $perlCmdString .= "nice ";
	 }
	 $perlCmdString .= "perl $string $genemarkDir/genemark.c.gtf $genome $flanking_DNA $genbank 2>$errorfile";
	 print LOG "\# ".(localtime).": create genbank file\n";
	 print LOG "$perlCmdString\n\n";
	 system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
     }
     
     # filter genbank file and only use the genes considered "good" (i.e. genes whose introns are represented in hints file) 
     if(!uptodate([$genbank, "$genemarkDir/genemark.f.good.gtf"],["$otherfilesDir/genbank.good.gb"])  || $overwrite){
	 print LOG "\# ".(localtime).": filtering genbank file\n";
	 $string=find("filterGenesIn_mRNAname.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	 $errorfile = "$errorfilesDir/filterGenesIn_mRNAname.stderr";
	 if(-z "$genemarkDir/genemark.f.good.gtf"){
	     print LOG "\# ".(localtime)." ERROR: The GeneMark-ET output file does not contain genes that are supported by the intron hints.\n";
	     print STDERR "ERROR: The GeneMark-ET output file does not contain genes that are supported by the intron hints.\n";
	     exit(1);
	 }
	 $perlCmdString = "";
	 if($nice){
	     $perlCmdString .= "nice ";
	 }
	 $perlCmdString .= "perl $string $genemarkDir/genemark.f.good.gtf $genbank 1>$otherfilesDir/genbank.good.gb 2>$errorfile";	 
	 print LOG "$perlCmdString\n\n";
	 system("$perlCmdString")==0 or die("failed to execute: $perlCmdString!\n");	 
    }

     # split into training and test set
     if(!uptodate(["$otherfilesDir/genbank.good.gb"],["$otherfilesDir/genbank.good.gb.test", "$otherfilesDir/genbank.good.gb.train"])  || $overwrite){
	 print LOG "\# ".(localtime).": Splitting genbank file into train and test file\n";
	 $string = find("randomSplit.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	 $errorfile = "$errorfilesDir/randomSplit.stderr";
	 if($nice){
	     $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	 }else{
	     $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	 }
	 if($gb_good_size < 300){
	     print LOG "\# ".(localtime)." WARNING: Number of good genes is low ($gb_good_size). Recomended are at least 300 genes\n";
        }
	 if($gb_good_size == 0){
	     print LOG "\# ".(localtime)." ERROR: Number of good genes is 0, so the parameters cannot be optimized. Recomended are at least 300 genes\n";
	     print STDERR "ERROR: Number of good genes is 0, so the parameters cannot be optimized. Recomended are at least 300 genes\n";
	     exit(1);
        }
        if($gb_good_size > 1000){
	        $testsize = 1000;
	        $perlCmdString = "";
	        if($nice){
	            $perlCmdString .= "nice ";
	        }
	        $perlCmdString .= "perl $string $otherfilesDir/genbank.good.gb $testsize 2>$errorfile";
	        print LOG "$perlCmdString\n\n";
	        system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
        }
     }
     
     if(!$useexisting){
	 # train AUGUSTUS for the first time
	 if(!uptodate(["$otherfilesDir/genbank.good.gb.train","$otherfilesDir/genbank.good.gb"],["$otherfilesDir/firstetraining.stdout"])){
	     # set "stopCodonExcludedFromCDS" to true
	     print LOG "\n\# ".(localtime).": Setting value of \"stopCodonExcludedFromCDS\" in $AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg to \"true\"\n";
	     setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "stopCodonExcludedFromCDS", "true"); # see autoAugTrain.pl
	     
	     # first try with etraining            
	     $augpath = "$AUGUSTUS_BIN_PATH/etraining";
	     $errorfile = "$errorfilesDir/firstetraining.stderr";
	     $stdoutfile = "$otherfilesDir/firstetraining.stdout";
	     if($nice){
		 $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }else{
		 $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }
	     $cmdString = "";
	     if($nice){
		 $cmdString .= "nice ";
	     }
	     if($gb_good_size <= 1000){
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
		 $testsize = $gb_good_size - 1;
	     }else{
		 $testsize = 1000;
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.train 1>$stdoutfile 2>$errorfile";
	     }
	     print LOG "\# ".(localtime).": first etraining\n";
	     print LOG "$cmdString\n\n";
	     system("$cmdString")==0 or die("Failed to execute $cmdString\n");
	     
	     # set "stopCodonExcludedFromCDS" to false and run etraining again if necessary
	     my $t_b_t = $gb_good_size - $testsize;
	     my $err_stopCodonExcludedFromCDS;
	     if($nice){
		 print LOG "nice grep -c \"exon doesn't end in stop codon\" $errorfile\n";
		 $err_stopCodonExcludedFromCDS = `nice grep -c "exon doesn't end in stop codon" $errorfile`;
	     }else{
		 print LOG "grep -c \"exon doesn't end in stop codon\" $errorfile\n";
		 $err_stopCodonExcludedFromCDS = `grep -c "exon doesn't end in stop codon" $errorfile`;
	     }
	     my $err_rate =  $err_stopCodonExcludedFromCDS / $t_b_t;  # see autoAugTrain.pl
	     print LOG "\# ".(localtime).": Error rate of missing stop codon is $err_rate\n"; # see autoAugTrain.pl
	     if($err_rate >= 0.5){ # see autoAugTrain.pl
		 print LOG "\n\# ".(localtime)."The appropriate value for \"stopCodonExcludedFromCDS\" seems to be \"false\".\n"; # see autoAugTrain.pl
		 print LOG "\n\# ".(localtime). "Setting value of \"stopCodonExcludedFromCDS\" in $AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg to \"false\"\n"; # see autoAugTrain.pl
		 setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "stopCodonExcludedFromCDS", "false");  # see autoAugTrain.pl
		 print LOG "\n\# ".(localtime).": Trying etraining again\n";
		 print LOG "$cmdString\n\n";
		 system("$cmdString")==0 or die("Failed to execute $cmdString\n");
	     }
	     
	     # adjust the stop-codon frequency in species_parameters.cfg according to train.out
	     print LOG "\# ".(localtime).": adjusting stop-codon frequencies in species_parameters.cfg according to $stdoutfile\n";
	     my $freqOfTag;          
	     my $freqOfTaa;          
	     my $freqOfTga;          
	     open(TRAIN, "$stdoutfile") or die ("Can not open file $stdoutfile!\n"); 
	     while(<TRAIN>){                 
		 if(/tag:\s*.*\((.*)\)/){    
		     $freqOfTag = $1;        
		 }elsif(/taa:\s*.*\((.*)\)/){
		     $freqOfTaa = $1;        
		 }elsif(/tga:\s*.*\((.*)\)/){
		     $freqOfTga = $1;        
		 }
	     }
	     close(TRAIN) or die("Could not close gff file $stdoutfile!\n");
	     print LOG "\# ".(localtime).": Setting frequency of stop codons to tag=$freqOfTag, taa=$freqOfTaa, tga=$freqOfTga.\n";
	     setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "/Constant/amberprob", $freqOfTag); 
	     setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "/Constant/ochreprob", $freqOfTaa); 
	     setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "/Constant/opalprob", $freqOfTga);  
	 }
	 
	 # first test
	 if(!uptodate(["$otherfilesDir/genbank.good.gb.test", "$otherfilesDir/genbank.good.gb"],["$otherfilesDir/firsttest.stdout"])  || $overwrite){
	     $augpath = "$AUGUSTUS_BIN_PATH/augustus";
	     $errorfile = "$errorfilesDir/firsttest.stderr";
	     $stdoutfile = "$otherfilesDir/firsttest.stdout";
	     if($nice){
		 print LOG "\# ".(localtime).": nice grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		 $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }else{
		 print LOG "\# ".(localtime).": grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		 $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }
	     $cmdString = "";
	     if($nice){
		 $cmdString .= "nice ";
	     }
	     if($gb_good_size <= 1000){
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
	     }else{
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.test 1>$stdoutfile 2>$errorfile";
	     }
	     print LOG "\# ".(localtime).": First AUGUSTUS accuracy test\n";
	     print LOG "$cmdString\n\n";
	     system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	     $target_1 = accuracy_calculator($stdoutfile);
	     print LOG "\# ".(localtime).": The accuracy after initial training (no optimize_augustus.pl, no CRF) is $target_1\n";      
	 }
	 
	 # optimize parameters
	 if(!$skipoptimize){
	     if(!uptodate(["$otherfilesDir/genbank.good.gb.train","$otherfilesDir/genbank.good.gb.test", "$otherfilesDir/genbank.good.gb"],[$AUGUSTUS_CONFIG_PATH."/species/$species/$species\_exon_probs.pbl", $AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", $AUGUSTUS_CONFIG_PATH."/species/$species/$species\_weightmatrix.txt"])){
		 $string=find("optimize_augustus.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
		 $errorfile = "$errorfilesDir/optimize_augustus.stderr";
		 $stdoutfile = "$otherfilesDir/optimize_augustus.stdout";
		 if($nice){
		     print LOG "\# ".(localtime).": nice grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		     $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
		 }else{
		     print LOG  "\# ".(localtime).": grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		     $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
		 }
		 $perlCmdString = "";
		 if($nice){
		     $perlCmdString .= "nice ";
		 }
		 if($gb_good_size <= 1000){
		     if($nice){
			 $perlCmdString .= "perl $string --nice --rounds=$rounds --species=$species --cpus=$CPU --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
		     }else{
			 $perlCmdString .= "perl $string --rounds=$rounds --species=$species --cpus=$CPU --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
		     }
		 }else{
		     if($nice){
			 $perlCmdString .= "perl $string --nice --rounds=$rounds --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH --onlytrain=$otherfilesDir/genbank.good.gb.train --cpus=$CPU $otherfilesDir/genbank.good.gb.test 1>$stdoutfile 2>$errorfile";
		     }else{
			 $perlCmdString .= "perl $string  --rounds=$rounds --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH --onlytrain=$otherfilesDir/genbank.good.gb.train --cpus=$CPU $otherfilesDir/genbank.good.gb.test 1>$stdoutfile 2>$errorfile";
		     }
		 }
		 print LOG "\# ".(localtime).": optimizing AUGUSTUS parameters\n";
		 print LOG "$perlCmdString\n\n";
		 system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString!\n");
		 print LOG "\# ".(localtime).":  parameter optimization finished.\n";
	     }
	 }

	 # train AUGUSTUS for the second time
	 if(!uptodate(["$otherfilesDir/genbank.good.gb.train","$otherfilesDir/genbank.good.gb"],["$otherfilesDir/secondetraining.stdout"])){
	     $augpath = "$AUGUSTUS_BIN_PATH/etraining";
	     $errorfile = "$errorfilesDir/secondetraining.stderr";
	     $stdoutfile = "$otherfilesDir/secondetraining.stdout";
	     if($nice){
		 $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }else{
		 $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }
	     $cmdString = "";
	     if($nice){
		 $cmdString .= "nice ";
	     }
	     if($gb_good_size <= 1000){
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
	     }else{
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.train 1>$stdoutfile 2>$errorfile";
	     }
	     print LOG "\# ".(localtime).": Second etraining\n";
	     print LOG "$cmdString\n\n";
	     system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	 }
	 
	 # second test
	 if(!uptodate(["$otherfilesDir/genbank.good.gb.test","$otherfilesDir/genbank.good.gb"],["$otherfilesDir/secondtest.out"]) || $overwrite){
	     $augpath = "$AUGUSTUS_BIN_PATH/augustus";
	     $errorfile = "$errorfilesDir/secondtest.stderr";
	     $stdoutfile = "$otherfilesDir/secondtest.stdout";
	     if($nice){
		 print LOG "\# ".(localtime).": nice grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		 $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }else{
		 print LOG "\# ".(localtime).": grep -c LOCUS $otherfilesDir/genbank.good.gb\n";
		 $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }
	     $cmdString = "";
	     if($nice){
		 $cmdString .= "nice ";
	     }
	     if($gb_good_size <= 1000){
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb >$stdoutfile 2>$errorfile";
	     }else{
		 $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.test >$stdoutfile 2>$errorfile";
	     }
	     print LOG "\# ".(localtime).": Second AUGUSTUS accuracy test\n";
	     print LOG "$cmdString\n\n";
	     system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
	     $target_2 = accuracy_calculator($stdoutfile);
	     print LOG "\# The accuracy after training (after optimize_augustus.pl, no CRF) is $target_2\n";                
	 }
	 
	 # optional CRF training
	 if($crf){
	     if(!uptodate(["$otherfilesDir/genbank.good.gb.test","$otherfilesDir/genbank.good.gb"],["$otherfilesDir/crftraining.stdout"]) || $overwrite){
		 $augpath = "$AUGUSTUS_BIN_PATH/etraining";
	     }
	     $errorfile = "$errorfilesDir/crftraining.stderr";
	     $stdoutfile = "$otherfilesDir/crftraining.stdout";
	     if($nice){
		 $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }else{
		 $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
	     }
	     $cmdString = "";
	     if($nice){
		 $cmdString .= "nice ";
	     }
	     if($gb_good_size <= 1000){
		 $cmdString .= "$augpath --species=$species --CRF=1 --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb 1>$stdoutfile 2>$errorfile";
	     }else{
		 $cmdString .= "$augpath --species=$species --CRF=1 --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.train 1>$stdoutfile 2>$errorfile";
	     }
	     print LOG "\# ".(localtime).": Third etraining - now with CRF\n";
	     print LOG "$cmdString\n\n";
	     system("$cmdString")==0 or die("failed to execute: $cmdString\n");
	     print LOG "\# ".(localtime).": etraining with CRF finished.\n";
	     
	     # third test
	     if(!uptodate(["$otherfilesDir/genbank.good.gb.test","$otherfilesDir/genbank.good.gb"],["$otherfilesDir/thirdtest.out"]) || $overwrite){
		 $augpath = "$AUGUSTUS_BIN_PATH/augustus";            
		 $errorfile = "$errorfilesDir/thirdtest.stderr";
		 $stdoutfile = "$otherfilesDir/thirdtest.stdout";
		 if($nice){
		     $gb_good_size = `nice grep -c LOCUS $otherfilesDir/genbank.good.gb`;
		 }else{
		     $gb_good_size = `grep -c LOCUS $otherfilesDir/genbank.good.gb`;
		 }
		 $cmdString = "";
		 if($nice){
		     $cmdString .= "nice ";
		 }
		 if($gb_good_size <= 1000){
		     $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb >$stdoutfile 2>$errorfile";
		 }else{
		     $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/genbank.good.gb.test >$stdoutfile 2>$errorfile";
		 }
		 print LOG "\# ".(localtime).": Third AUGUSTUS accuracy test\n";
		 print LOG "$cmdString\n\n";
		 system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
		 $target_3 = accuracy_calculator($stdoutfile);
		 print LOG "\# The accuracy after CRF training is $target_2\n";    
	     }
	     
	     # decide on whether to keep CRF parameters
	     if($target_2>$target_3){
		 print LOG "\# ".(localtime).": CRF performance is worse than HMM performance, reverting to usage of HMM paramters.\n";
	     }else{
		 print LOG "\# ".(localtime).": CRF performance is better than HMM performance, keeping CRF paramters.\n";
	     }
	     # cp config files
	     print LOG "\# ".(localtime).": Copying parameter files to $species*.CRF\n";
	     for(("$species"."_exon_probs.pbl","$species"."_igenic_probs.pbl", "$species"."_intron_probs.pbl")){
		 $cmdString = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_ cp $AUGUSTUS_CONFIG_PATH/species/$species/$_".".CRF";
		 print LOG "$cmdString\n";
		 system("$cmdString")==0 or die("failed to execute: $cmdString\n");
	     }
	     # if the accuracy doesn't improve with CRF, overwrite the config files with the HMM parameters from last etraining
	     if($target_2>$target_3){
		 print LOG "\# ".(localtime).": overwriting parameter files resulting from CRF training with original HMM files\n";
		 for(("$species"."_exon_probs.pbl","$species"."_igenic_probs.pbl", "$species"."_intron_probs.pbl")){
		     $cmdString = "rm $AUGUSTUS_CONFIG_PATH/species/$species/$_";
		     print LOG "$cmdString\n";
		     system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
		     print LOG "$cmdString\n";
		     $cmdString = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_".".HMM $AUGUSTUS_CONFIG_PATH/species/$species/$_";
		     system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
		 }
	     }	          
	 }
     }
     
    # copy species files to working directory
     if(! -d "$parameterDir/$species"){
	 $cmdString = "";
	 if($nice){
	     $cmdString .= "nice ";
	 }
	 $cmdString .= "cp -r $AUGUSTUS_CONFIG_PATH/species/$species $parameterDir";
	 print LOG "\# ".(localtime).": Copying optimized parameters to working directory $parameterDir\n";
	 print LOG "$cmdString\n\n";
	 system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
     }
}



         ####################### run AUGUSTUS  #########################
# run AUGUSTUS for given species with given options
sub augustus{
    my $localUTR = shift;
    my $scriptpath;
    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    if(defined($augustus_scripts_path)){
	$scriptpath = $AUGUSTUS_SCRIPTS_PATH;
    }elsif(defined($AUGUSTUS_BIN_PATH)){
	$scriptpath = "$AUGUSTUS_BIN_PATH/../scripts";
    }else{
	$scriptpath = "$AUGUSTUS_CONFIG_PATH/../scripts";
    }
    my $extrinsic;
    my @genome_files;
    my $pm;
    if(defined($extrinsicCfgFile) && -f $extrinsicCfgFile){
	$extrinsic = $extrinsicCfgFile;
    }elsif($useexisting || ! -f "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg"){
	$extrinsic = "$AUGUSTUS_CONFIG_PATH/extrinsic/extrinsic.M.RM.E.W.cfg";
    }else{
	$extrinsic = "$AUGUSTUS_CONFIG_PATH/species/$species/extrinsic.$species.cfg";
    }
 
    if(!uptodate([$extrinsic,$hintsfile, $genome],["$otherfilesDir/augustus.gff"])  || $overwrite){
	# split genome file in smaller parts and use multiple parallel runs of augustus for prediction
	if($CPU > 1){
	    print LOG "\# ".(localtime).": splitting genome file in smaller parts for parallel execution of AUGUSTUS prediction\n";
	    $string = find("splitMfasta.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);    
	    $errorfile = "$errorfilesDir/splitMfasta.stderr";
	    my $minsize = floor($genome_length / $CPU);
	    $perlCmdString = "";
	    if($nice){
		$perlCmdString .= "nice ";
	    }
	    $perlCmdString .= "perl $string $genome --outputpath=$otherfilesDir --minsize=$minsize 2>$errorfile";
	    print LOG "$perlCmdString\n";
	    system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
	    if($nice){
		print LOG "\# ".(localtime).": nice find $otherfilesDir -name \"genome.split.*\"\n";
		@genome_files = `nice find $otherfilesDir -name "genome.split.*"`;
	    }else{
		print LOG "\# ".(localtime).": find $otherfilesDir -name \"genome.split.*\"\n";
		@genome_files = `find $otherfilesDir -name "genome.split.*"`;
	    }
	    print LOG "\# ".(localtime).": Split genome file in ".scalar(@genome_files)." parts, finished.\n";
	}else{
	    push(@genome_files, $genome);
	}
	@genome_files = sort {lc($a) cmp lc($b)} @genome_files;
	$pm = new Parallel::ForkManager($CPU);
	for(my $i = 0; $i < scalar(@genome_files); $i++){
	    chomp($genome_files[$i]);
	    my $pid = $pm->start and next;
	    my $idx = $i + 1;
	    $errorfile = "$errorfilesDir/augustus.$idx.stderr";
	    $stdoutfile = "$otherfilesDir/augustus.$idx.gff";
	    $cmdString = "";
	    if($nice){
		$cmdString .= "nice ";
	    }
	    $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH --extrinsicCfgFile=$extrinsic --alternatives-from-evidence=$alternatives_from_evidence --hintsfile=$hintsfile --UTR=$localUTR";
	    if(defined($optCfgFile)){
		$cmdString .= " --optCfgFile=$optCfgFile"; 
	    }
	    if($soft_mask){
		$cmdString .= " --softmasking=1";
	    }
	    if(defined($augustus_args)){
		$cmdString .= " $augustus_args";
	    }
	    $cmdString .= " $genome_files[$i] 1>$stdoutfile 2>$errorfile";
	    print LOG "\# ".(localtime).": Running AUGUSTUS for file $genome_files[$idx-1]\n";
	    print LOG "$cmdString\n\n";
	    system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	    $pm->finish;
	}
	$pm->wait_all_children;
	print LOG "\# ".(localtime).": AUGUSTUS prediction complete\n";
	# join prediction files to one file
	if($CPU > 1){
	    $string = find("join_aug_pred.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	    my $cat_file = "$otherfilesDir/augustus.tmp.gff";
	    for(my $idx = 1; $idx <= scalar(@genome_files); $idx++){
		$cmdString = "";
		if($nice){
		    $cmdString .= "nice ";
		}
		$cmdString .= "cat $otherfilesDir/augustus.$idx.gff >> $cat_file";
		print LOG "\# ".(localtime).": Concatenating AUGUSTUS output files\n";
		print LOG "$cmdString\n";
		system("$cmdString")==0 or die("Failed to execute $cmdString\n");
	    }
	    $perlCmdString = "";
	    if($nice){
		$perlCmdString .= "nice ";
	    }
	    $perlCmdString .= "perl $string <$cat_file >$otherfilesDir/augustus.gff";
	    print LOG "\# ".(localtime).": Joining AUGUSTUS output\n";
	    print LOG "$perlCmdString\n\n";
	    system("$perlCmdString")==0 or die("Failed to execute $perlCmdString\n");
	    for(my $idx = 1; $idx <= scalar(@genome_files); $idx++){
		unlink("$otherfilesDir/augustus.$idx.gff");
		print LOG "\# ".(localtime).": Deleting $otherfilesDir/augustus.$idx.gff\n";
	    }
	    unlink("$otherfilesDir/augustus.tmp.gff");
	    print LOG "\# ".(localtime).": Deleting $otherfilesDir/augustus.tmp.gff\n";
	}else{
	    $cmdString = "";
	    if($nice){
		$cmdString .= "nice ";
	    }
	    $cmdString .= "mv $otherfilesDir/augustus.1.gff $otherfilesDir/augustus.gff";
	    print LOG "\# ".(localtime).": renaming AUGUSTUS file\n";
	    print LOG "$cmdString\n\n";
	    system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
	}
    }
}

# call getAnnoFasta.pl
sub getAnnoFasta{
    my $AUG_pred = shift;
    @_ = split(/\//, $AUG_pred);
    my $name_base = substr($_[-1],0,-4);
    my $string = find("getAnnoFasta.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    my $errorfile = "$errorfilesDir/getAnnoFasta.$name_base.stderr";
    $perlCmdString = "";
    if($nice){
	$perlCmdString .= "nice ";
    }
    my $perlCmdString .= "perl $string $AUG_pred 2>$errorfile";
    print LOG "\# ".(localtime).": Making a fasta file with protein sequences of $AUG_pred\n";
    print LOG "$perlCmdString\n\n";
    system("$perlCmdString")==0 or die("Failed to execute: $perlCmdString\n");
}

# make gtf file
sub make_gtf{
    my $AUG_pred = shift;
    @_ = split(/\//, $AUG_pred);
    my $name_base = substr($_[-1],0,-4);
    my $gtf_file = substr($AUG_pred,0,-4).".gtf";
    my $errorfile = "$errorfilesDir/gtf2gff.$name_base.gtf.stderr";
    my $perlstring = find("gtf2gff.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    $cmdString = "";
    if($nice){
	$cmdString .= "nice ";
    }
    my $cmdString .= "cat $AUG_pred | perl -ne 'if(m/\\tAUGUSTUS\\t/){print \$_;}' | perl $perlstring --printExon --out=$gtf_file 2>$errorfile";
    print LOG "\# ".(localtime).": Making a gtf file from $AUG_pred\n";
    print LOG "$cmdString\n\n";
    system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
    if($gff3){
	my $gff3_file = substr($AUG_pred,0,-4).".gff3";
	my $errorfile = "$errorfilesDir/gtf2gff.$name_base.gff3.stderr";
	my $perlstring = find("gtf2gff.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	my $cmdString .= "cat $AUG_pred | perl -ne 'if(m/\\tAUGUSTUS\\t/){print \$_;}' | perl $perlstring --printExon -gff3 --out=$gff3_file 2>$errorfile";
	print LOG "\# ".(localtime).": Making a gff3 file from $AUG_pred\n";
	print LOG "$cmdString\n\n";
	system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
    }
}   
  

         ####################### delete all zero sized files #########################
# delete empty files
sub clean_up{
    print LOG "\# ".(localtime).": deleting empty files\n";
    if($nice){
	print LOG "\# ".(localtime).": nice find $otherfilesDir -empty\n";
	@files = `nice find $otherfilesDir -empty`;
    }else{
	print LOG "\# ".(localtime).": find $otherfilesDir -empty\n";
        @files = `find $otherfilesDir -empty`;
    }    
    for(my $i=0; $i <= $#files; $i++){
	chomp($files[$i]); # to prevent error: Unsuccessful stat on filename containing newline
	if(-f $files[$i]){
	    print LOG "rm $files[$i]\n";
	    unlink(rel2abs($files[$i]));
	}
    }    
}



         ########################### some checks beforehand ############################
# check upfront whether any common problems will occur later
# find out if some programs are not installed. 
# checks for GeneMark-ET: perl modules: YAML, Hash::Merge, Logger::Simple, Parallel::ForkManager
# checks for braker: perl modules: Scalar::Util::Numeric
sub check_upfront{ # see autoAug.pl

    # check whether required perl modules are installed
    my $pmodule;
    my @module_list = (
	"YAML",
	"Hash::Merge",
	"Logger::Simple",
	"Parallel::ForkManager",
	"Scalar::Util::Numeric"
	);
    
    foreach my $module (@module_list){  
	$pmodule = check_install(module => $module);
	if(!$pmodule){
	    print STDOUT "WARNING: Perl module '$module' is required but not installed yet.\n";
	}
    }
    
    # check whether environmental variables are set or other path variables are defined
    if(!$ENV{'AUGUSTUS_CONFIG_PATH'} && !defined($augustus_cfg_path)){ # see autoAug.pl
	print STDERR "ERROR: The environment variable AUGUSTUS_CONFIG_PATH is not defined. Please export an environment variable for AUGUSTUS or use --AUGUSTUS_CONFIG_PATH=path/to/augustus/config .\n"; # see autoAug.pl
	exit(1);
    }

    if(!defined($augustus_bin_path)){
	print STDOUT "WARNING: The command line option --AUGUSTUS_BIN_PATH was not used. This is ok if binaries of augustus reside in ../bin relative to AUGUSTUS_CONFIG_PATH. Otherwise, please specify --AUGUSTUS_BIN_PATH\n";
    }
    
    if(!defined($augustus_scripts_path)){
	print STDOUT "WARNING: The command line option --AUGUSTUS_SCRIPTS_PATH was not used. This is ok if scripts of augustus reside in ../scripts relative to AUGUSTUS_CONFIG_PATH or AUGUSTUS_BIN_PATH (will first look for them in AUGUSTUS_BIN_PATH). Otherwise, please specify --AUGUSTUS_SCRIPTS_PATH\n";
    }
  
    if(!$ENV{'GENEMARK_PATH'} && !defined($GMET_path)){
	print STDERR "ERROR: The environment variable GENEMARK_PATH to the 'gmes_petap.pl' script is not defined. Please export an environment variable or use --GENEMARK_PATH=path/to/gmes_petap.pl.\n"; 
	exit(1);
    }

    if(!$ENV{'ALIGNMENT_TOOL_PATH'} && !defined($ALIGNMENT_TOOL_PATH) && @prot_seq_files){
	print STDERR "ERROR: The environment variable  ALIGNMENT_TOOL_PATH to either the exectuable of GenomeThreader, Exonerate or Spaln is not defined. Please export an environment variable or use --ALIGNMENT_TOOL_PATH=path/to/aligner.\n";
    }

    if(!$ENV{'BAMTOOLS_PATH'} && !defined($bamtools_path)){ # see autoAug.pl
	print STDERR "ERROR: The environment variable BAMTOOLS_PATH is not defined. Please export an environment variable for bamtools or use --BAMTOOLS_PATH=path/to/bamtools.\n"; # see autoAug.pl
	exit(1);
    }

    # check for augustus executable
    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    if(system("$augpath > /dev/null 2> /dev/null") != 0){                   # see autoAug.pl
	if(! -f $augpath){                                                    # see autoAug.pl
	    print STDERR "ERROR: augustus executable not found at $augpath.\n"; # see autoAug.pl
	}else{
	    print STDERR "ERROR: $augpath not executable on this machine.\n";   # see autoAug.pl
	}
	exit(1);
    }
  
    # check whether bamtools is installed
    if(system("which $BAMTOOLS_BIN_PATH/bamtools > /dev/null") != 0){
	print STDERR "Error: bamtools not installed. Please install it first.\n";
	exit (1);
    }
    
    # check for etraining executable
    my $etrainpath;
    $etrainpath = "$AUGUSTUS_BIN_PATH/etraining";
    if(system("$etrainpath > /dev/null 2> /dev/null") != 0){                   
	if(! -f $etrainpath){                                                    
	    print STDERR "ERROR: etraining executable not found at $etrainpath.\n";
	}else{
	    print STDERR "ERROR: $etrainpath not executable on this machine.\n";
	}
	exit(1);
    }

    # check whether bam2wig is executable
    $bam2wigPath = "$AUGUSTUS_BIN_PATH/../auxprogs/bam2wig/bam2wig";
    if($UTR eq "on" && $skipAllTraining==0){ # MIGHT WANT TO CHANGE THIS!
	if(not(-x $bam2wigPath)){
	    if(! -f $bam2wigPath){
		print STDERR "ERROR: bam2wig executable not found at $bam2wigPath.\n";
	    }else{
		print STDERR "ERROR: $bam2wigPath not executable on this machine.\n";
	    }
	    print STDERR "       UTR training from RNA-Seq is enabled. This requires bam2wig. Please check README.TXT of AUGUSTUS to compile bam2wig correctly.\n";
	    exit(1);
	}
    }

    # check whether rnaseq2utr is executable
    $rnaseq2utrPath = "$AUGUSTUS_BIN_PATH/../auxprogs/utrrnaseq/trunks/Debug/utrrnaseq"; # FIX WHEN TOOL MIGRATES TO AUGUSTUS REPOSITORY BEFORE RELEASE!
    if($UTR eq "on" && $skipAllTraining==0){
	if(not(-x $rnaseq2utrPath)){
	    if(! -f $rnaseq2utrPath){
		print STDERR "ERROR: rnaseq2utr executable not found at $rnaseq2utrPath.\n";
	    }else{
		print STDERR "ERROR: $rnaseq2utrPath not executable on this machine.\n";
	    }
	    print STDERR "       UTR training from RNA-Seq is enabled. This requires rnaseq2utr. Please check README.TXT of AUGUSTUS to compile rnaseq2utr correctly.\n";
	    exit(1);
	}
    }
  

    # check for alignment executable and in case of SPALN for environment variables
    my $prot_aligner;
    if(@prot_seq_files){
	if($prg eq 'gth'){
	    $prot_aligner = "$ALIGNMENT_TOOL_PATH/gth";
	    if(! -f $prot_aligner){
		print STDERR "ERROR: GenomeThreader executable not found at $prot_aligner.\n";
		exit(1);
	    }elsif(! -x $prot_aligner){
		print STDERR "ERROR: $prot_aligner not executable on this machine.\n";
		exit(1);
	    }
	}elsif($prg eq 'spaln'){
	    $prot_aligner = "$ALIGNMENT_TOOL_PATH/spaln";
	    if(! -f $prot_aligner){
		print STDERR "ERROR: Spaln executable not found at $prot_aligner.\n";
		exit(1);
	    }elsif(! -x $prot_aligner){
		print STDERR "ERROR: $prot_aligner not executable on this machine.\n";
		exit(1);
	    }
	    # check whether spaln environment variables are configured
	    if(!$ENV{'ALN_DBS'} or !$ENV{'ALN_TAB'}){
		if(!$ENV{'ALN_DBS'}){
		    print STDERR "ERROR: The environment variable ALN_DBS for spaln is not defined. Please export an\
 environment variable with:' export ALN_DBS=/path/to/spaln/seqdb'\n";
		}
		if(!$ENV{'ALN_TAB'}){
		    print STDERR "ERROR: The environment variable ALN_TAB for spaln is not defined. Please export an\
 environment variable with:' export ALN_TAB=/path/to/spaln/table'\n";
		}
		exit(1);
	    }
	}elsif($prg eq 'exonerate'){
	    $prot_aligner = "$ALIGNMENT_TOOL_PATH/exonerate";
	    if(! -f $prot_aligner){
		print STDERR "ERROR: Exonerate executable not found at $prot_aligner.\n";
		exit(1);
	    }elsif(! -x $prot_aligner){
		print STDERR "ERROR: $prot_aligner not executable on this machine.\n";
		exit(1);
	    }
	    
	}
    }
    
  
    # check whether the necessary perl scripts exist and can be found
    find("gff2gbSmallDNA.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("filterGenemark.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("new_species.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("filterGenesIn_mRNAname.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("join_mult_hints.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("randomSplit.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("optimize_augustus.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("splitMfasta.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("join_aug_pred.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("getAnnoFasta.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("gtf2gff.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("startAlign.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    find("align2hints.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
}



# check whether hints file is in gff format
sub check_gff{
    my $gfffile = shift;
    print LOG "\# ".(localtime).": Checking if input file $gfffile is in gff format\n";
    open (GFF, $gfffile) or die "Cannot open file: $gfffile\n";
    my $nIntrons = 0;
    my $printedAllowedHints = 0;
    my %foundFeatures;
    while(<GFF>){
	my @gff_line = split(/\t/, $_);
	if(scalar(@gff_line) != 9){
	    print LOG "\# ".(localtime)." ERROR: File $gfffile is not in gff format!\n";
	    print STDERR "ERROR: File $gfffile is not in gff format!\n";
	    close(GFF) or die("Could not close gff file $gfffile!\n");
	    exit(1);
	}else{
	    if(!isint($gff_line[3]) || !isint($gff_line[4]) || $gff_line[5] =~ m/[^\d\.]/g || $gff_line[6] !~ m/[\+\-\.]/ || length($gff_line[6]) != 1 || $gff_line[7] !~ m/[0-2\.]{1}/ || length($gff_line[7]) != 1){
		print LOG "\# ".(localtime)." ERROR:File $gfffile is not in gff format!\n";
		print STDERR "ERROR: File $gfffile is not in gff format!\n";
		close(GFF) or die("Could not close gff file $gfffile!\n");
		exit(1);
	    }
	}
	# intron hints are the sole source of extrinsic information for GeneMark-ET, thus, if no bam file is given, the
	# supplied hints file must contain intron hints (many)
	if(!@bam){
	    if($gff_line[2] eq "intron"){
		$nIntrons++;
	    }
	}
	# if no extrinsic.cfg is specified, parameters in braker.pl written extrinsic.cfg correspond to hints in @allowedHints, only; other hints will be treated with neutral malus/bonus. Issue corresponding warning.
	if(not(defined($extrinsicCfgFile))){
	    my $isAllowed = 0;
	    foreach(@allowedHints){
		if($gff_line[2] eq $_){
		    $isAllowed = 1;
		}
	    }
	    if($isAllowed != 1){
		if(not(defined($foundFeatures{$gff_line[2]}))){	
		    print LOG "\# ".(localtime)." WARNING: File $gfffile contains hints of a feature type $gff_line[2] that is currently not supported by BRAKER. Features of this type will be treated with neutral bonus/malus in the extrinsic.cfg file that will be used for running AUGUSTUS.\n";
		    $foundFeatures{$gff_line[2]} = 1;
		}
		if($printedAllowedHints == 0){
		    print LOG "Currently allowed hint types:\n";
		    print STDERR "Currently allowed hint types:\n";
		    foreach(@allowedHints){
			print LOG $_."\n";
			print STDERR $_."\n";
		    }
		    $printedAllowedHints = 1;
		}
	    }	
	}
    }
    close(GFF) or die("Could not close gff file $gfffile!\n");
    if(!@bam){
	if($nIntrons < 1000){
	    print LOG "\# ".(localtime)." ERROR: Since no bam file was supplied, GeneMark-ET must take intron information from hints file $gfffile. This file contains only $nIntrons intron hints. GeneMark-ET training will thus likely fail. Aborting braker.pl!\n";
	    print STDERR "ERROR: Since no bam file was supplied, GeneMark-ET must take intron information from hints file $gfffile. This file contains only $nIntrons intron hints. GeneMark-ET training will thus likely fail. Aborting braker.pl!\n";
	    exit(1);
	}
    }
}

# check whether all options are set correctly
sub check_options{
    if($alternatives_from_evidence ne "true" && $alternatives_from_evidence ne "false"){
	print STDERR "ERROR: \"$alternatives_from_evidence\" is not a valid option for --alternatives-from-evidence. Please use either 'true' or 'false'.\n";
	exit(1);
    } 
    
    if($UTR ne "on" && $UTR ne "off"){
	print STDERR "ERROR: \"$UTR\" is not a valid option for --UTR. Please use either 'on' or 'off'.\n";
	exit(1);
    }
    
    if(($UTR eq "on" && $soft_mask==0) or ($UTR eq "on" && not(@bam))){
	print STDERR "ERROR: --UTR=on has been set but --softmasking has not been enabled. A softmasked genome file and the option --softmasking and a bam file must be provided in order to run --UTR=on.\n";
	exit(1)
    }

    my $operatingSystem = "$^O";
    my $cpus_available = 1;
    if($operatingSystem eq "linux"){
	$cpus_available = `nproc`;
    }else{ # Mac OS X
	$cpus_available = `sysctl -n hw.ncpu`;
    }

    if($cpus_available < $CPU){
	print STDOUT "WARNING: Your system does not have $CPU cores available, only $cpus_available. Braker will use the $cpus_available available instead of the chosen $CPU.\n";
    }
}

# check fasta headers
sub check_fasta_headers{            # see autoAug.pl
    my $fastaFile = shift;            # see autoAug.pl
    my $someThingWrongWithHeader = 0; # see autoAug.pl
    my $spaces = 0;                   # see autoAug.pl
    my $orSign = 0;                   # see autoAug.pl
    my $emptyC = 0;                   # see simplifyFastaHeaders.pl
    my $wrongNL = 0;                  # see simplifyFastaHeaders.pl
    my $prot = 0;                     # see simplifyFastaHeaders.pl
    my $dna = 0;                      # see simplifyFastaHeaders.pl
    my $mapFile = "$otherfilesDir/header.map";
    my $stdStr = "This may later on cause problems! The pipeline will create a new file without spaces or \"|\" characters and a header.map file to look up the old and new headers. This message will be suppressed from now on!\n";
    if(!uptodate([$genome],["$otherfilesDir/genome.fa"]) || $overwrite){
	print LOG "\# ".(localtime).": Checking fasta headers\n";
	open(FASTA, "<", $fastaFile) or die("Could not open fasta file $fastaFile!\n");
	open(OUTPUT, ">", "$otherfilesDir/genome.fa") or die("Could not open fasta file $otherfilesDir/genome.fa!\n");
	open(MAP, ">", $mapFile) or die("Could not open map file $mapFile.\n");
	while(<FASTA>){
	    # check newline character
	    if(not($_ =~ m/\n$/)){  # see simplifyFastaHeaders.pl
		if($wrongNL < 1){     # see simplifyFastaHeaders.pl
		    print LOG "\# ".(localtime)." WARNING: something seems to be wrong with the newline character! This is likely to cause problems with the braker.pl pipeline and the AUGUSTUS web service! Please adapt your file to UTF8! This warning will be supressed from now on!\n"; # see simplifyFastaHeaders.pl
		    $wrongNL++;         # see simplifyFastaHeaders.pl
		}
	    }
	    chomp;
	    # look for whitespaces in fasta file
	    if($_ =~ m/\s/){      # see autoAug.pl
		if($spaces == 0){   # see autoAug.pl
		    print LOG "\# ".(localtime)." WARNING: Detected whitespace in fasta header of file $fastaFile. ".$stdStr;		 
		    $spaces++;        # see autoAug.pl
		}
	    }
	    # look for | in fasta file
	    if($_ =~ m/\|/){      # see autoAug.pl
		if($orSign == 0){   # see autoAug.pl
		    print LOG "\# ".(localtime)." WARNING: Detected | in fasta header of file $fastaFile. ".$stdStr;
		    $orSign++;        # see autoAug.pl
		}
	    }	   
	    # look for special characters in headers
	    if(($_ !~ m/[>a-zA-Z0-9]/) && ($_ =~ m/^>/) ){
		if($someThingWrongWithHeader==0){   # see autoAug.pl
		    print LOG "\# ".(localtime)." WARNING: Fasta headers in file $fastaFile seem to contain non-letter and non-number characters. That means they may contain some kind of special character. ".$stdStr; 	
		    $someThingWrongWithHeader++;      # see autoAug.pl
		}
	    }	    
	    if($_ =~ m/^>/){
		# replace | and whitespaces by _
		my $oldHeader = $_;
		$_ =~ s/\s/_/g;
		$_ =~ s/\|/_/g;
		print OUTPUT "$_\n";
		print MAP "$_\t$oldHeader\n";
	    }else{
		if(length($_) > 0){    # see simplifyFastaHeaders.pl
		    $genome_length += length($_);
		    print OUTPUT "$_\n"; # see simplifyFastaHeaders.pl
		    if($_ !~ m/[ATGCNatgcn]/){ # see simplifyFastaHeaders.pl
			if($dna == 0){ # see simplifyFastaHeaders.pl
			    print LOG "\# ".(localtime).": Assuming that this is not a DNA fasta file because other characters than A, T, G, C, N, a, t, g, c, n were contained. If this is supposed to be a DNA fasta file, check the content of your file! If this is supposed to be a protein fasta file, please ignore this message!\n"; # see simplifyFastaHeaders.pl
			    $dna++;      # see simplifyFastaHeaders.pl
			}
		    }
		    if($_ !~ m/[AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjXx]/){ # see simplifyFastaHeaders.pl
			if($prot == 0){ # see simplifyFastaHeaders.pl
			    print LOG "\# ".(localtime).": Assuming that this is not a protein fasta file because other characters than AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjXx were contained. If this is supposed to be DNA fasta file, please ignore this message.\n"; # see simplifyFastaHeaders.pl
			    $prot++;      # see simplifyFastaHeaders.pl
			}
		    }
		}else{
		    if($emptyC < 1){  # see simplifyFastaHeaders.pl
			print LOG "\# ".(localtime)." WARNING: empty line was removed! This warning will be supressed from now on!\n";
		    } 
		    $emptyC++;        # see simplifyFastaHeaders.pl
		}
	    }
	}
	close(FASTA) or die("Could not close fasta file $fastaFile!\n");
	close(OUTPUT) or die("Could not close output fasta file $otherfilesDir/genome.fa!\n");
	close(MAP) or die("Could not close map file $mapFile!\n");
    } 
    $genome = "$otherfilesDir/genome.fa";
}

# check bam headers
sub check_bam_headers{ 
    my $bamFile = shift;
    my $someThingWrongWithHeader = 0; # see autoAug.pl
    my $spaces = 0;                   # see autoAug.pl
    my $orSign = 0;                   # see autoAug.pl
    my %map_hash;
    my $mapFile = "$otherfilesDir/bam_header.map";
    my $stdStr = "This may later on cause problems! The pipeline will create a new file without spaces or \"|\" characters and a bam_header.map file to look up the old and new headers, if samtools is working on your system. This message will be suppressed from now on!\n";
    @_ = split(/\//, $bamFile); 
    @_ = split(/\./, $_[-1]);
    my $samHeaderFile = "$otherfilesDir/".$_[0]."_header.sam";
    my $samHeaderFile_new = "$otherfilesDir/".$_[0]."_new_header.sam";
    if(!uptodate([$bamFile],["$otherfilesDir/$bamFile"]) || $overwrite){
	# extract header information 
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "$BAMTOOLS_BIN_PATH/bamtools header -in $bamFile > $samHeaderFile";
	print LOG "\# ".(localtime).": create header file $samHeaderFile\n";
	print LOG "$cmdString\n\n";
	system("$cmdString")==0 or die("Failed to execute: $cmdString!\n");
	open(SAM, "<", $samHeaderFile) or die("Could not open SAM file $samHeaderFile!\n");
	open(OUTPUT, ">", "$samHeaderFile_new") or die("Could not open SAM file $samHeaderFile_new!\n");
	open(MAP, ">", $mapFile) or die("Could not open map file $mapFile.\n");
	while(<SAM>){
	    chomp;
	    # only check sequence entries
	    if($_ =~ m/^\@SQ/){
		my @seq_line = split(/\t/, $_);
		my $seq_end = $seq_line[-1];		
		@seq_line = split(/\:/, $seq_line[1]);
		my $old_name = $seq_line[1];
		my $new_name = $old_name;
		# remove whitespaces, if necessary
		@seq_line = split(/\s/, $seq_line[1]);
		if(scalar(@seq_line) > 1){
		    if($spaces == 0){
			print LOG "\# ".(localtime)." WARNING: Detected whitespace in BAM header of file $bamFile. ".$stdStr; # see autoAug.pl
			$spaces++;        # see autoAug.pl
		    }
		}
		$new_name =~ s/\s/_/g; # removing whitespaces (if any)
		@seq_line = split(/\|/, $old_name);
		if(scalar(@seq_line) > 1){
		    if($orSign == 0){   # see autoAug.pl
			print LOG "\# ".(localtime)." WARNING: Detected | in header of file $bamFile. ".$stdStr; # see autoAug.pl
			print LOG "Replacing | by underscores in Bam headers.\n";
			$orSign++;        # see autoAug.pl
		    }
		}
		$new_name =~ s/\|/_/g; # replace or signs by underscores (if any)
		$map_hash{$old_name} = $new_name;
		$seq_line[0] = "\@SQ\tSN:$new_name\t$seq_end";
		if($seq_line[0] !~ m/[>a-zA-Z0-9]/){
		    if($someThingWrongWithHeader==0){   # see autoAug.pl
			print LOG  "\# ".(localtime)." WARNING: BAM headers in file $bamFile seem to contain non-letter and non-number characters. That means they may contain some kind of special character. ".$stdStr; # see autoAug.pl
			$someThingWrongWithHeader++;      # see autoAug.pl
		    }
		}
		print OUTPUT "$seq_line[0]\n";   # see simplifyFastaHeaders.pl
		print MAP "$map_hash{$old_name}\t$old_name\n";  # see simplifyFastaHeaders.pl
	    }elsif(eof){
		print OUTPUT "$_";
	    }else{
		print OUTPUT "$_\n";
	    }
	}
	close(SAM) or die("Could not close header file $samHeaderFile!\n");
	close(OUTPUT) or die("Could not close output SAM file $samHeaderFile_new!\n");
	close(MAP) or die("Could not close map file $mapFile!\n");
	print LOG "\# ".(localtime).": Deleting SAM header file $samHeaderFile (will not be needed from here on)\n";
	unlink($samHeaderFile);
	# something wrong with header part
	if($spaces != 0 || $orSign != 0 || $someThingWrongWithHeader != 0){
	    # no samtools installed. stop here
	    if(system("which samtools > /dev/null") != 0){
		print LOG "\# ".(localtime)." ERROR: BAM file $bamFile contains spaces, \"|\" or some other kind of special characters.\n";
		print LOG  "'samtools' not installed. BAM file cannot be fixed automatically.\n";
		print STDERR "BAM file $bamFile contains spaces, \"|\" or some other kind of special characters.\n";
		exit(1);
		# samtools installed. try to correct BAM file
	    }else{
		if(!$ENV{'SAMTOOLS_PATH'} && !defined($SAMTOOLS_PATH_OP)){
		    print LOG "\# ".(localtime)." WARNING: The environment variable SAMTOOLS_PATH is not defined. Please export an environment variable for samtools or use --SAMTOOLS_PATH=path/to/samtools.\n"; # see autoAug.pl
		    print LOG "The program will try to use 'samtools' to start samtools, which may not work on your system.\n"; # see autoAug.pl
		    $SAMTOOLS_PATH = "samtools";
		}
		my $samFile = "$otherfilesDir/".$_[0].".sam";
		my $samFile_new = "$otherfilesDir/".$_[0]."_new.sam";
		$cmdString = "";
		if($nice){
		    $cmdString .= "nice ";
		}
		$cmdString .= "$SAMTOOLS_PATH view $bamFile > $samFile";
		print LOG "\# ".(localtime).": convert BAM to SAM file $samFile\n";
		print LOG "$cmdString\n\n";
		system("$cmdString")==0 or die("failed to execute: $cmdString!\n");
		open(SAM, "<", $samFile) or die("Could not open SAM file $samFile!\n");
		open(OUTPUT, ">", "$samFile_new") or die("Could not open SAM file $samFile_new!\n");
		while(<SAM>){
		    chomp;
		    my @line = split(/\t/, $_);
		    $line[2] = $map_hash{$line[2]};
		    if(eof){
			print OUTPUT join("\t", @line);
		    }else{
			print OUTPUT join("\t", @line)."\n";
		    }
        }
		close(SAM) or die("Could not close SAM file $samFile!\n");
		close(OUTPUT) or die("Could not close output SAM file $samFile_new!\n");
		$cmdString = "";
		if($nice){
		    $cmdString .= "nice ";
		}
		$cmdString .= "cat $samHeaderFile_new $samFile_new > $samFile";
		print LOG "\# ".(localtime).": concatenate new header and SAM file\n";
		print LOG "$cmdString\n\n";
		system("$cmdString")==0 or die("failed to execute: $cmdString!\n");
		print LOG "\# ".(localtime).": Deleting $samFile_new\n";
		unlink($samFile_new);

		$cmdString = "";
		if($nice){
		    $cmdString .= "nice ";
		}
		$cmdString = "$SAMTOOLS_PATH view -bSh $samFile > $otherfilesDir/".$_[0].".bam";
		print LOG "\# ".(localtime).": Converting new SAM file to BAM format\n";
		print LOG "$cmdString\n\n";
		system("$cmdString")==0 or die("failed to execute: $cmdString!\n");
		print LOG "\# ".(localtime).": Deleting $samFile\n";
		unlink($samFile);
		$bamFile = "$otherfilesDir/".$_[0].".bam";
	    }
	}
	print LOG "\# ".(localtime).": Deleting $samHeaderFile_new\n";
	unlink($samHeaderFile_new);
    } 
    return $bamFile;
} 

# calculate the result of testing AUGUSTUS on genbank files in a single number 
sub accuracy_calculator{
    my $aug_out=shift;
    my ($nu_sen, $nu_sp, $ex_sen, $ex_sp, $gen_sen, $gen_sp);
    open(AUGOUT, "$aug_out") or die ("Could not open $aug_out!\n");
    while(<AUGOUT>){
        if(/^nucleotide level\s*\|\s*(\S+)\s*\|\s*(\S+)/){
            $nu_sen=$1;
            $nu_sp=$2;
        }
        if(/^exon level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/){
            $ex_sen=$1;
            $ex_sp=$2;
        }
        if(/^gene level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/){
            $gen_sen=$1;
            $gen_sp=$2;
        }
    }
    my $target=(3*$nu_sen+2*$nu_sp+4*$ex_sen+3*$ex_sp+2*$gen_sen+1*$gen_sp)/15;
    return $target;
}

# UTR training from rnaseq2utr
sub train_utr{
    print LOG "\# ".(localtime).": Move augustus predictions to *.noUTR.* files prior UTR training:\n";
    # store predictions without UTRs, revert later if UTR model does not improve predictions
    print LOG "mv $otherfilesDir/augustus.gff $otherfilesDir/augustus.noUtr.gff\n";
    move("$otherfilesDir/augustus.gff", "$otherfilesDir/augustus.noUtr.gff");
    print LOG "mv $otherfilesDir/augustus.gtf $otherfilesDir/augustus.noUtr.gtf\n";
    move("$otherfilesDir/augustus.gtf", "$otherfilesDir/augustus.noUtr.gtf");
    print LOG "mv $otherfilesDir/augustus.aa $otherfilesDir/augustus.noUtr.aa\n";
    move("$otherfilesDir/augustus.aa", "$otherfilesDir/augustus.noUtr.aa");
    # copy species parameter files, revert later if UTR model does not improve predictions
    print LOG "\# ".(localtime).": Create backup of current species parameters:\n";
    for(("$species"."_exon_probs.pbl","$species"."_igenic_probs.pbl", "$species"."_intron_probs.pbl")){
	print LOG "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_ $AUGUSTUS_CONFIG_PATH/species/$species/$_.noUTR\n";
	copy("$AUGUSTUS_CONFIG_PATH/species/$species/$_", "$AUGUSTUS_CONFIG_PATH/species/$species/$_.noUTR") or die ("Copy failed!\n");
    }
    chdir($otherfilesDir) or die ("Could not change into directory $otherfilesDir!\n");
    # search all start and stop codons from augustus.noUtr.gtf and write them to the file stops.and.starts.gff
    if (!uptodate(["augustus.noUtr.gtf"],["stops.and.starts.gff"])){	
	print LOG "\# ".(localtime).": extracting all stop and start codons from augustus.noUtr.gtf to stops.and.starts.gff\n";
	my %nonRedundantCodons;
	my @tmpGffLine;
	open(AUG, "<", "augustus.noUtr.gtf") or die ("Could not open file augustus.noUtr.gtf!\n");
	while(defined(my $i=<AUG>)){
	    # TODO: we are not dealing with redundancy, correctly. Discarding duplicates is not the optimal solution
	    #       because later, we filter for genes where both codons have UTR models. However, at this point in
	    #       time, we ignore this matter and hope that we are left with a sufficient number of training
	    #       examples.
	    if($i=~/\t(start_codon|stop_codon)\t/) {
		@tmpGffLine = split(/\t/, $i);
		if(not(defined($nonRedundantCodons{"$tmpGffLine[0]_$tmpGffLine[3]_$tmpGffLine[4]_$tmpGffLine[6]"}))){
		    $nonRedundantCodons{"$tmpGffLine[0]_$tmpGffLine[3]_$tmpGffLine[4]_$tmpGffLine[6]"} = $i;
		}
	    };
	}
	close(AUG) or die ("Could not close file augustus.noUtr.gtf!\n");
	open(CODON, ">", "stops.and.starts.gff") or die ("Could not open file stops.and.starts.gff!\n");
	foreach my $key (keys %nonRedundantCodons){
	    print CODON $nonRedundantCodons{$key};
	}
	close(CODON) or die ("Could not close file stops.and.starts.gff!\n");
    }
    if(!uptodate(["$hintsfile"], ["rnaseq.utr.hints"])){
	# TODO: currently, only using AT-AG, not AC-AG or any other splice site. Possibly extend to other splice patterns.
	print LOG "\# ".(localtime).": filtering RNA-Seq hints for valid splice site AT-AG, storing in rnsaeq.utr.hints\n";
	my %genome_hash;
	my $hash_key;
	open (FASTA , "<", $genome) or die ("Could not open file $genome!\n");
        LINE: while (my $line = <FASTA>){
	    next LINE if $line =~ m/^#/; #discard comments
	    if ($line =~ /^>/){
		chomp($line);
		$hash_key = substr($line, 1, length($line)-1);
	    }else{
		$line =~ s/[\x0A\x0D]+//g;
		$line =~ s/(\s+)(\n)(\r)//g;
		$line = uc($line);
		$genome_hash{$hash_key}.=$line;
	    }
	}
	close(FASTA) or die("Could not close file $genome!\n");
	open (HINTS, "<", $hintsfile) or die ("Could not open file $hintsfile!\n");
	my @gff;
	my ($siteA, $siteB, $given, $lastCol);
	my $splice = "ATAG";
	open (UTRHINTS, ">", "rnaseq.utr.hints") or die ("Could not open file rnaseq.utr.hints!\n");
        LINE: while(my $line = <HINTS>){
	    @gff = split(/\t/, $line);
	    if(($gff[1] eq "b2h") && ($gff[2] eq "intron")){ # make sure to use only intron hints from RNA-Seq data
		$siteA = substr($genome_hash{$gff[0]}, ($gff[3]-1), 2);
		$siteB = substr($genome_hash{$gff[0]}, ($gff[4]-2), 2);
		$given = $siteA.$siteB;
		if($gff[8]=~m/mult=(\d+)/){
		    $lastCol="mult=$1_$splice\n";
		}else{
		    $lastCol="mult=1_$splice\n";
		}
		if(uc($given) =~ m/$splice/){
		    print $gff[0]."\t".$gff[1]."\t".$gff[2]."\t".$gff[3]."\t".$gff[4]."\t".$gff[5]."\t+\t".$gff[7]."\t".$lastCol;
		}else{
		    $given = reverse $given;
		    $given =~ tr/ACGTacgt/TGCAtgca/;
		    if(uc($given) =~ m/$splice/){
			print $gff[0]."\t".$gff[1]."\t".$gff[2]."\t".$gff[3]."\t".$gff[4]."\t".$gff[5]."\t-\t".$gff[7]."\t".$lastCol;
		    }
		}
	    }
	}
	close(UTRHINTS) or die("Could not close file rnaseq.utr.hints!\n");
	close(HINTS) or die("Could not close file $hintsfile!\n");
    }
    # create wiggle file from bam files
    if(!uptodate(["$hintsfile"], ["rnaseq.wig"])){
	if(scalar(@bam)>1){
	    print LOG "\# ".(localtime).": converting bam files to wiggle file rnaseq.wig\n";
	    $cmdString = "";
	    if($nice){
		$cmdString .= "nice ";
	    }
	    $cmdString .= "$BAMTOOLS_BIN_PATH/bamtools merge ";
	    foreach(@bam){
		chomp;
		$cmdString .= "-in $_ ";
	    }
	    $cmdString .= "-out merged.bam";
	    print LOG "\n$cmdString\n\n";
	    system("$cmdString") or die ("Failed to execute: $cmdString!\n");
	}else{
	    print LOG "\# ".(localtime).":  Creating softlink to bam file $bam[0]...\n";
	    $cmdString = "ln -s $bam[0] merged.bam";
	    print LOG "$cmdString\n";
	    system($cmdString)==0 or die("Failed to exectute: $cmdString!\n");
	}
	print LOG "\# ".(localtime).": Creating wiggle file...\n";
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "$bam2wigPath merged.bam >merged.wig 2> $otherfilesDir/bam2wig.err";
	print LOG "\n$cmdString\n";
	system("$cmdString")==0 or die ("Failed to execute: $cmdString!\n");
    }
    # call utrrnaseq
    if(!uptodate(["$hintsfile"], ["utrs.gff"])){
	print LOG  "\# ".(localtime).": Creating utrs.gff\n";
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "$rnaseq2utrPath -G $genome -O stops.and.starts.gff -I rnaseq.utr.hints -W rnaseq.wig --outFileName=utrs.gff $rnaseq2utr_args 2> $otherfilesDir/rnaseq2utr.err";
	print LOG "\n$cmdString\n";
	system("$cmdString")==0 or die ("Failed to execute: $cmdString!\n");
    }
    # create genbank file with genes that have to utrs
    if (!uptodate(["utrs.gff", "augustus.noUtr.gtf"], ["bothutr.lst", "bothutr.test.gb"])){
	print LOG  "\# ".(localtime).": Creating gb file for UTR training\n";
	# extract subset of genes, where we have both UTRs
	open(UTR, "<", "utrs.gff") or die ("Can not open utrs.gff!\n");
	open(TRLST, ">", "tr.lst");
	while(<UTR>){
	    s/.*\t(\S+UTR)\t.*transcript_id \"(\S+)\".*/$2\t$1/;
	    print TRLST;
	}
	close(UTR) or die ("Could not close file utrs.gff!\n");
	close(TRLST) or die("Could not close file tr.lst!\n");
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "cat tr.lst | sort -u > tr_temp.lst";
	print LOG "\n$cmdString\n";
	system($cmdString)==0 or die("Failed not execute $cmdString!\n");
	print LOG "\nrm tr.lst\n";
	unlink("tr.lst");
	$cmdString = "mv tr_temp.lst tr.lst";
	print LOG "\n$cmdString\n";
        system($cmdString)==0 or die("Failed not execute $cmdString!\n");
	open(TR, "tr.lst") or die ("Can not open tr.lst!\n");
	open(BOTH, ">", "bothutr.lst");
	my $Fld1;
	my $prev;
	while(<TR>){
	    ($Fld1) = split('\t', $_, -1);
	    if($Fld1 eq $prev){
		print BOTH "$prev\n";
	    }
	}
	close(TR) or die ("Could not close file tr.lst!\n");
	close(BOTH) or die ("Could not close file bothutr.lst!\n");
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "cat utrs.gff augustus.noUtr.gtf > genes.gtf_temp";
	print LOG "\n$cmdString\n";
	system($cmdString)==0 or die("Failed not execute $cmdString!\n");
	open(GENES, "<", "genes.gtf_temp") or die ("Can not open the file genes.gtf_temp!\n");
	open(WRITEGENES, ">", "genes.gtf_unsort");
	while(<GENES>){
	    if(/(CDS|UTR)\t/){print WRITEGENES}
	}
	close(GENES) or die ("Could not close file genes.gtf_temp!\n");
	close(WRITEGENES) or die ("Could not close file genes.gtf_unsort!\n");
	$cmdString = "";
	if($nice){
	    $cmdString .= "nice ";
	}
	$cmdString .= "cat genes.gtf_unsort | sort -n -k 4,4 | sort -s -k 10,10 | sort -s -k 1,1 > genes.gtf";
	print LOG "\n$cmdString\n";
	system($cmdString)==0 or die("Failed not execute $cmdString!\n");
	$string = find("gff2gbSmallDNA.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	$perlCmdString="perl $string genes.gtf $genome $flanking_DNA bothutr.test.gb --good=bothutr.lst 1> $otherfilesDir/gff2gbSmallDNA.utr.stdout 2> $otherfilesDir/gff2gbSmallDNA.utr.stderr";
	print LOG "\n$perlCmdString\n";
	system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString!\n");
    }
    # create train.gb and onlytrain.gb
    # train.gb contains a small proportion of genes with utr and up to 150 genes with UTR
    # onlytrain.gb contains all other genes (with and without utr)
    if (!uptodate(["bothutr.test.gb", "../training.gb.train.test"] , ["train.gb", "onlytrain.gb"])){
	# evaluate m: size of smaller set of utr examples
	my $m;
	# count the block number in bothutr.test.gb
	my $count=0;
	open(TEMP1, "<", "bothutr.test.gb") or die ("Can not open the file bothutr.test.gb! \n");
	while(<TEMP1>){
	    $count++ if($_=~m/LOCUS/);
	}
	close(TEMP1) or die("Could not close file bothutr.test.gb!\n");
	if($count>=150){$m=150}else{$m=$count};
	if($count<50){
	    die( "ERROR: Number of UTR training examples is smaller than 50. Abort UTR training. If this is the only error message, the AUGUSTUS parameters for your species were optimized ok, but you are lacking UTR parameters. Do not attempt to predict genes with UTRs for this species using the current parameter set!\n");
	    exit;
	}
	# evaluate n: size of smaller set of no utr examples
	my $n; 
	# count the block number in training.gb.train.test
	$count=0;
	open(TEMP2,"genbank.good.gb.test") or die ("Can not open the file genbank.good.gb.test!\n");
	while(<TEMP2>){
	    $count++ if($_=~m/LOCUS/);
	}
	close(TEMP2) or die("Could not close file genbank.good.gb.test!\n");
	if($count>=50){$n=50}else{$n=$count};
	# extract traininging set for UTR model
	$string=find("randomSplit.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	print LOG "Found script $string.\n";
	$perlCmdString="perl $string bothutr.test.gb $m";
	print LOG "\nperlCmdString\n";
	system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString!\n");
	$perlCmdString="perl $string genbank.good.gb.test $n";
	print LOG "\n$perlCmdString\n";
	system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString!\n");
	my $delete;
	open(GB, "<", "genbank.good.gb.test.test") or die ("Can not open file genbank.good.gb.test.test!\n");
	open(NOMRNA, ">", "nomrna.test.gb") or die("Could not open file nomrna.test.gb!\n");
	while(<GB>){
	    $delete=1 if /mRNA/;
	    $delete=0 if /CDS/;
	    print NOMRNA if (!$delete);
	}
	close(GB) or die("Could not close file genbank.good.gb.test.test!\n");
	close(NOMRNA) or die("Could not close file nomrna.test.gb!\n");
	$cmdString = "cat nomrna.test.gb bothutr.test.gb.test > train.gb";
	print LOG "\n$cmdString\n";
	system("$cmdString")==0 or die("Failed to execute: $cmdString\n");
	# count how many genes are contained in train.gb
	my $counter_gen=0;
	open(TS, "train.gb");
	while(<TS>){
	    $counter_gen++ if(/^     CDS             /);
	}
	close(TS) or die ("Could not close file train.gb!\n");
	print LOG "Have constructed a training set train.gb for UTRs with $counter_gen genes\n";
	print LOG "Deleting nomrna.test.gb, genbank.good.gb.test.test, genbank.good.gb.test.train\n";
	unlink("nomrna.test.gb");
	unlink("genbank.good.gb.test.test");
	unlink("genbank.good.gb.test.train");
        # create onlytrain training set only used for training #                                                           
        open(ONLYTRAIN, "<", "genbank.good.gb.train") or die ("Could not open file genbank.good.gb.train!\n");
        open(CDSONLY, ">", "cdsonly.gb") or die ("Could not open file cdsonly.gb!\n");
        # delete the mRNA part up to the next CDS tag
        $delete=0;
        while(<ONLYTRAIN>){
            $delete=1 if /mRNA/;
            $delete=0 if /CDS/;
            print CDSONLY if (!$delete);
        }
        close(ONLYTRAIN) or die("Could not close file genbank.good.gb.train!\n");
        close(CDSONLY) or die("Could not close file cdsonlyl.gb!\n");
        # construct the disjoint sets: remove training UTR genes from onlytrain UTR gene set (train.utronly.gb)
        open(TRAIN, "<", "train.gb") or die ("Could not open the file train.gb!\n");
        open(REMOVE, ">", "remove.lst") or die ("Could not open file remove.lst!\n");
        my $locustag = 0;
        while(<TRAIN>){    
            if(m/LOCUS\s+(\S+)_\d+-\d+/){
		$locustag = 0; 
		print REMOVE "$1_";
	    }elsif(m/gene="(\S+)\.t\d+/){
		if($locustag==0){
		    print REMOVE $1."\n";
		} 
		$locustag = 1;
		
	    }	    
        }
        close(TRAIN) or die("Could not close file train.gb!\n");
        close(REMOVE) or die ("Could not close file remove.lst!\n");
        $string=find("filterGenes.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
        print LOG "Found script $string.\n";
        $perlCmdString="perl $string remove.lst bothutr.test.gb > train.utronly.gb";
	print LOG "\n$perlCmdString\n";
        system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString!\n");
	$cmdString = "cat cdsonly.gb train.utronly.gb > onlytrain.gb";
	print LOG "\n$cmdString\n";
        system("$cmdString")==0 or die("failed to execute: $cmdString!\n");
	# changing UTR parameters in species config file to "on"
	print STDOUT "NEXT STEP: Setting value of \"UTR\" in $AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg to \"true\"\n";
	print LOG "\n\# ".(localtime).": Setting value of \"UTR\" in $AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg to \"true\"\n";
	setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "UTR", "on");
	setParInConfig($AUGUSTUS_CONFIG_PATH."/species/$species/$species\_parameters.cfg", "print_utr", "on");
    }
    if (!uptodate(["train.gb", "onlytrain.gb"], ["optimize.utr.out"])){
	# prepare metaparameter file
	my $metaUtrName= $species."_metapars.utr.cfg";
	if(not(-e $AUGUSTUS_CONFIG_PATH."/species/$species/$metaUtrName")){
	    # copy from generic as template
	    $cmdString = "cp $AUGUSTUS_CONFIG_PATH"."/species/generic/generic_metapars.utr.cfg $AUGUSTUS_CONFIG_PATH"."/species/$species/$metaUtrName";
	    print LOG "Copying utr metaparameter template file:\n$cmdString\n";
	    system("$cmdString")==0 or die ("Failed to execute: $cmdString!\n");
	}
	$string=find("optimize_augustus.pl", $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
	print LOG "Found script $string.\n";
	$perlCmdString="perl $string --rounds=$rounds --species=$species --trainOnlyUtr=1 --onlytrain=onlytrain.gb  --metapars=$AUGUSTUS_CONFIG_PATH"."/species/$species/$metaUtrName train.gb --UTR=on > optimize.utr.out";
	print LOG "Now optimizing meta parameters of AUGUSTUS for the UTR model:\n";
	print LOG "Running \"$perlCmdString\"...";
	system("$perlCmdString")==0 or die ("Failed to execute: $perlCmdString!\n");
    } else {
	print "Skipping UTR parameter optimization. Already up to date.\n";
    }
    
    
    
    
    
}