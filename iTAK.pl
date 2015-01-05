#!/usr/bin/perl

=head1
 iTAK -- Plant Transcription factor & Protein Kinase Identifier and Classifier

 yz357@cornell.edu

 update
	[Dec-31-2014][v1.5]: combination rules for plantTFDB and plnTFDB, new classification system for future rule update
	[Jan-19-2014][v1.4]: new category system for plant protein kinase, from RKD and HMM build by Shiu et al. 2012 
		     update the hmmscan to version 3.1, 2x faster than hmm 3.0
	[Jun-22-2013][v1.3]: update some small bugs, Pfam V27, WAK and WAKL family, a switch for transponsase filter
	[Aug-26-2011][v1.2]: report unusual sequences
	[Jun-03-2011][v1.1]: remove unsignificiant domain using GA score
	[Dec-14-2010][v1.0]: first stable version 
=cut

use strict;
use warnings;
use Cwd;
use File::Basename;
use Bio::SeqIO;
use IO::File;
use Bio::SearchIO;
use Getopt::Std;
use FindBin;
use lib "$FindBin::RealBin/bin";
use itak;

my $version = 1.5;
my $debug = 0;

my %options;
getopts('a:b:c:d:e:f:g:i:j:k:l:m:n:o:p:q:r:s:t:u:v:w:x:y:z:h', \%options);
unless (defined $options{'t'} ) { usage($version); }

if	($options{'t'} eq 'identify')	{ itak_identify(\%options, \@ARGV); }
elsif	($options{'t'} eq 'database')	{ itak_database(\%options, \@ARGV); }
else	{ usage($version); }

#################################################################
# kentnf: subroutine						#
#################################################################
=head2
 itak_identify -- identification of TFs or PKs
=cut
sub itak_identify
{
	my ($options, $files) = @_;

	my $usage =qq'
USAGE:  perl $0 [options] input_seq 

        -a  [Integer]   number of CPUs used for hmmscan. (default = 1)
        -o  [String]    Name of the output directory. ( default = \'input file
                        name\' + \'_output\')

';

	# +++++ check input parameters +++++
	print $usage and exit unless $$files[0];
	foreach my $f (@$files) {
		my $output_dir = $f."_output";
		my $temp_dir = $f."_temp";
		print "[WARN]output folder exist: $output_dir\n" if -e $output_dir;
		print "[WARN]temp folder exist: $temp_dir\n" if -e $temp_dir;
		die "[ERR]input file not exist\n" unless -s $f;
	}
	
	my $cpu = '20';
	$cpu = $$options{'p'} if defined $$options{'p'} &&  $$options{'p'} > 0; 

	# +++++ set database and script +++++
	my $bin_dir = ${FindBin::RealBin}."/bin";
	my $dbs_dir = ${FindBin::RealBin}."/database";
	unless (-e $bin_dir) { die "[ERR]bin folder not exist.\n$bin_dir\n"; }
	unless (-e $dbs_dir) { die "[ERR]database folder not exist.\n $dbs_dir\n"; }
	
	my $pfam_db    = $dbs_dir."/TFHMM_3.hmm";		# database for transcription factors (Pfam-A + customized)
	my $plantsp_db = $dbs_dir."/PlantsPHMM3_89.hmm";	# plantsP kinase
	my $shiu_db    = $dbs_dir."/Plant_Pkinase_fam.hmm";	# shiu kinase database
	foreach my $db (($pfam_db, $plantsp_db, $shiu_db)) {
		die "[ERR]database file $db\n" unless (-s $db.".h3f" && -s $db.".h3i" && -s $db.".h3m" && -s $db.".h3p");
	}

	my $tf_rule = $dbs_dir."/TF_Rule.txt";              	# Rules for Transcription Factors
	my $correct_ga = $dbs_dir."/GA_table.txt";		# update GA cutoff
	my $pk_desc = $dbs_dir."/PK_class_desc.txt";		# PK family description (for PPC)
	my $hmmscan_bin = $bin_dir."/hmmscan";			# hmmscan 
	my $hmmpress_bin = $bin_dir."/hmmpress";		# hmmpress

	foreach my $f (($tf_rule, $correct_ga, $pk_desc, $hmmscan_bin, $hmmpress_bin)) {
		die "[ERR]file not exist: $f\n" unless -s $f;
	}

	my %tf_rule = load_rule($tf_rule);
	my %ga_cutoff = load_ga_cutoff($pfam_db, $correct_ga);
	my $pkid_des = pk_to_hash($pk_desc);

	# +++++ main +++++ 
	foreach my $f (@$files)
	{
		# create folder for temp files and output files
		my $temp_dir = $f."_temp";
		my $output_dir = $f."_output";
		mkdir($temp_dir) unless -e $temp_dir;
		mkdir($output_dir) unless -e $output_dir;

		my $input_protein_f = $temp_dir."/protein_seq.fa";			# input protein sequence
		my $tmp_pfam_hmmscan = $temp_dir."/protein_seq.pfam.hmmscan.txt";	# temp hmmscan result compared to Pfam-A + customized
		my $report_info = '';

		# put seq to hash
		# key: id, alphabet, seq; value: alphabet, seq
		# proteins to temp file
		my %seq_info = seq_to_hash($f);
		$report_info = "Load ".scalar(keys(%seq_info))." sequences.\n\nNot protein sequence ID:\n";

		my $outp = IO::File->new(">".$input_protein_f) || die $!;
		foreach my $id (sort keys %seq_info) {

			if ($seq_info{$id}{'alphabet'} eq 'protein') {
				print $outp ">".$id."\n".$seq_info{$id}{'seq'}."\n";
			} else {
				$report_info.= "$id\n";
			}
		}
		$outp->close;
		print "[ERR]no input proteins\n" unless -s $input_protein_f;

		# ==== Part A TF identification ====
		# ==== A1. compare input seq with database ====
		my $hmmscan_command = "$hmmscan_bin --acc --notextw --cpu $cpu -o $tmp_pfam_hmmscan $pfam_db $input_protein_f";
		#run_cmd($hmmscan_command);
		run_cmd($hmmscan_command) unless -s $tmp_pfam_hmmscan; # test code
		my ($hmmscan_hit_1, $hmmscan_detail_1) = itak::parse_hmmscan_result($tmp_pfam_hmmscan);

		# ==== A2. TF identification ====
		my %qid_tid = itak_tf_identify($hmmscan_hit_1, $hmmscan_detail_1, \%ga_cutoff, \%tf_rule);

		# ==== A3. save the result ====
		my $output_sequence	  = "$output_dir/tf_sequence.txt";
		my $output_alignment	  = "$output_dir/tf_alignment.txt";
		my $output_classification = "$output_dir/tf_classification.txt";
		itak_tf_write_out(\%qid_tid, \%seq_info, $hmmscan_detail_1, \%tf_rule, $output_sequence, $output_alignment, $output_classification);
		
		# ==== Part B PK identification ====
		# ==== B1. get protein kinase sequence ====
		my %pkinase_id;
		chomp($hmmscan_hit_1); my @hit_line = split(/\n/, $hmmscan_hit_1);
		foreach my $line ( @hit_line ) {
			my @a = split(/\t/, $line);
			$a[1] =~ s/\..*//;
			if ($a[1] eq 'PF00069' ) {
				die "[ERR]no GA for PF00069" unless defined $ga_cutoff{$a[1]};
				$pkinase_id{$a[0]} = 1 if $a[2] >= $ga_cutoff{$a[1]};
			} 

			if ($a[1] eq 'PF07714') {
				die "[ERR]no GA for PF07714" unless defined $ga_cutoff{$a[1]};
				$pkinase_id{$a[0]} = 1 if $a[2] >= $ga_cutoff{$a[1]};
			}
		}
		
		my $tmp_pkinase_seq = $temp_dir."/pkinase_seq.fa"; 
		my $out1 = IO::File->new(">".$tmp_pkinase_seq) || die $!;
		foreach my $id (sort keys %pkinase_id) {
			print $out1 ">".$id."\n".$seq_info{$id}{'seq'}."\n";
		}
		$out1->close;

		# ==== B2. compare input seq with databas ====
                my $tmp_plantsp_hmmscan = "$temp_dir/protein_seq.plantsp.hmmscan.txt";
                my $tmp_shiu_hmmscan    = "$temp_dir/protein_seq.shiu.hmmscan.txt";
		#my $tmp_rkd_hmmscan     = "$temp_dir/protein_seq.rkd.hmmscan.txt";

		my $plantsp_hmmscan_cmd = "$hmmscan_bin --acc --notextw --cpu $cpu -o $tmp_plantsp_hmmscan $plantsp_db $tmp_pkinase_seq";
		my $shiu_hmmscan_cmd    = "$hmmscan_bin --acc --notextw --cpu $cpu -o $tmp_shiu_hmmscan    $shiu_db    $tmp_pkinase_seq";
		#my $rkd_hmmscan_cmd     = "$hmmscan_bin --acc --notextw --cpu $cpu -o $tmp_rkd_hmmscan     $rkd_db    $tmp_pkinase_seq";

		run_cmd($plantsp_hmmscan_cmd) unless -s $tmp_plantsp_hmmscan;
		run_cmd($shiu_hmmscan_cmd) unless -s $tmp_shiu_hmmscan;
		my ($plantsp_hit, $plantsp_detail) = itak::parse_hmmscan_result($tmp_plantsp_hmmscan);
		my ($shiu_hit, $shiu_detail)       = itak::parse_hmmscan_result($tmp_shiu_hmmscan);

		# ==== B3. PK classification ====		
		my %plantsp_cat = itak_pk_classify($plantsp_hit);
                my %shiu_cat = itak_pk_classify($shiu_hit);

                # ==== B4 classification of sub pkinase ====
		my @wnk1 = ("$dbs_dir/wnk1_hmm_domain/WNK1_hmm",   "30" , "PPC:4.1.5", "PPC:4.1.5.1");
		my @mak  = ("$dbs_dir/mak_hmm_domain/MAK_hmm", "460.15" , "PPC:4.5.1", "PPC:4.5.1.1");
		my @sub = (\@wnk1, \@mak);

		foreach my $s ( @sub ) {
			# check array info for sub classify
			die "[ERR]sub classify info ".join(",", @$s)."\n" unless scalar(@$s) == 4;
			my ($hmm_profile, $cutoff, $cat, $sub_cat) = @$s;

			# get seq for sub classify
			my $seq_num = 0;
			my $ppc_seq = "$temp_dir/temp_ppc_seq";
			my $ppfh = IO::File->new(">".$ppc_seq) || die $!;
			foreach my $seq_id (sort keys %plantsp_cat) {
				if ( $plantsp_cat{$seq_id} eq $cat ) {
               				die "[ERR]seq id: $seq_id\n" unless defined $seq_info{$seq_id}{'seq'};
                                	print $ppfh ">".$seq_id."\n".$seq_info{$seq_id}{'seq'}."\n";
                                	$seq_num++;
				}
                        }
			$ppfh->close;

			# next if there is no seq
			next if $seq_num == 0;

			# hmmscan and parse hmm result
        		my $ppc_hmm_result = $temp_dir."/temp_ppc_sub_hmmscan.txt";
        		my $hmm_cmd = "$hmmscan_bin --acc --notextw --cpu $cpu -o $ppc_hmm_result $hmm_profile $ppc_seq";
			run_cmd($hmm_cmd) unless -s $ppc_hmm_result;
        		my ($ppc_hits, $ppc_detail) = itak::parse_hmmscan_result($ppc_hmm_result);
			my @hit = split(/\n/, $ppc_hits);

			foreach my $h (@hit) {
				my @a = split(/\t/, $h);
				$plantsp_cat{$a[0]} = $sub_cat if $a[2] >= $cutoff;
			}
                }

                # %pkinases_cat = get_wnk1(\%pkinases_cat, "$dbs_dir/wnk1_hmm_domain/WNK1_hmm" , "30" ,"PPC:4.1.5", "PPC:4.1.5.1");""
                # $$pkid_des{"PPC:4.1.5.1"} = "WNK like kinase - with no lysine kinase";
                # %pkinases_cat = get_wnk1(\%pkinases_cat, "$dbs_dir/mak_hmm_domain/MAK_hmm" , "460.15" ,"PPC:4.5.1", "PPC:4.5.1.1");
                # $$pkid_des{"PPC:4.5.1.1"} = "Male grem cell-associated kinase (mak)";
        
		#foreach my $pid (sort keys %pkinases_cat) {
                #        print $ca_fh1 $pid."\t".$pkinases_cat{$pid}."\t".$$pkid_des{$pkinases_cat{$pid}}."\n";
                #}
                #$ca_fh1->close;

		# ==== B5 save result =====
		# output plantsp classification
		my $ppc_cat = $output_dir."/PPC_classification.txt";
		my $ppc_aln = $output_dir."/PPC_alignment.txt";

                my $ca_fh1 = IO::File->new(">".$ppc_cat) || die $!;
                my $al_fh1 = IO::File->new(">".$ppc_aln) || die $!;
		foreach my $pid (sort keys %plantsp_cat) { print $ca_fh1 $pid."\t".$plantsp_cat{$pid}."\t".$$pkid_des{$plantsp_cat{$pid}}."\n"; }

=head
                foreach my $pid (sort keys %pkinases_cat)
                {
                        if (defined $pkinase_aln{$pid})
                        {
                                print $al_fh1 $pkinase_aln{$pid};
                        }
                        else
                        {
                                die "Error! Do not have alignments in hmm3 parsed result\n";
                        }
                        delete $pkinase_id{$pid};
                }

                foreach my $pid (sort keys %pkinase_id)
                {
                        print $ca_fh1 $pid."\tPPC:1.Other\n";

                        if (defined $pkinase_aln{$pid})
                        {
                                print $al_fh1 $pkinase_aln{$pid};
                        }
                        else
                        {
                                die "Error! Do not have alignments in hmm3 parsed result\n";
                        }
                }
=cut
		$ca_fh1->close;
                $al_fh1->close;
		
                # output Shiu classification
		my $shiu_cat = $output_dir."/shiu_classification.txt";
                my $shiu_aln = $output_dir."/shiu_alignment.txt";

                my $ca_fh2 = IO::File->new(">".$shiu_cat) || die $!;
                my $al_fh2 = IO::File->new(">".$shiu_aln) || die $!;
                foreach my $pid (sort keys %shiu_cat) { print $ca_fh2 $pid."\t".$shiu_cat{$pid}."\n"; }
                #print $al_fh2 $hmm3_shiu_align;
                $ca_fh2->close;
                $al_fh2->close;	

		print $report_info."\n";
		# remove temp folder
		# run_cmd("rm -rf $temp_dir") if -s $temp_dir;
	}
}

=head2
 itak_database -- prepare itak database
=cut
sub itak_database
{
	my ($options, $files) = @_;

        my $usage =qq'
USAGE:  perl $0 -t database  ftp://ftp.ebi.ac.uk/pub/databases/Pfam/releases/Pfam27.0/Pfam-A.hmm.gz 

';
	print $usage and exit unless $$files[0];

	# check file exist
	my $bin_dir = ${FindBin::RealBin}."/bin";
	my $dbs_dir = ${FindBin::RealBin}."/database";
	unless (-e $bin_dir) { die "[ERR]bin folder not exist.\n$bin_dir\n"; }
	unless (-e $dbs_dir) { die "[ERR]database folder not exist.\n $dbs_dir\n"; }

	my $pfam_db = $dbs_dir."/TFHMM_3.hmm";                  # database for transcription factors (Pfam-A + customized)
	die "[ERR]database exist $pfam_db\n" if -s $pfam_db;
	my $TF_selfbuild = $dbs_dir."/TF_selfbuild.hmm";
	die "[ERR]selfbuild hmm not exist $TF_selfbuild\n" unless -s $TF_selfbuild;
	my $hmmpress_bin = $bin_dir."/hmmpress";		# hmmspress
	die "[ERR]hmmpress not exist\n" unless -s $hmmpress_bin;

	# build database;
	my $pfam_a_gz = $$files[0];	$pfam_a_gz =~ s/.*\///;
	my $pfam_a = $pfam_a_gz;	$pfam_a =~ s/\.gz//;
	my $hmmscan_bin = $bin_dir."/hmmscan";                  # hmmscan
	
	# run_cmd("wget $$files[0]");
	# run_cmd("gunzip $pfam_a_gz");
	# run_cmd("cat $pfam_a $TF_selfbuild > $pfam_db");
	# run_cmd("$hmmpress_bin $pfam_db");
	# unlink($pfam_a);
	
	print qq'
wget $$files[0]
gunzip $pfam_a_gz
cat $pfam_a $TF_selfbuild > $pfam_db
$hmmpress_bin $pfam_db
rm $pfam_a

';
	exit;
}

my %seq_hash;
=head
#########################################################
# After Protein Kinase Prediction, Two Char Produced	#
# 1. temp_all_hmmscan_family				#
# 2. temp_all_hmmscan_domain				#
#########################################################

if ($mode =~ m/^p|b$/i)
{
	# Step 3.1 produce protein kinase sequence
	# pkinase_id has the protein ID with high GA score in Pfam Kinase domain
	# key: gene_id, value: 1; 
	my %pkinase_id = cutoff($all_hits, \%transposase);

	# pkinase_aln
	# key: gene_id, value: align detail for gene
	my %pkinase_aln = aln_to_hash($all_detail);

	my $protein_kinase_seq = $output_dir."/".$input_seq."_pkseq";

	my $pk_seq_num = scalar(keys(%pkinase_id));

	if ($pk_seq_num > 0)
	{
		# save protein kinase sequence to fasta file (with protein kinases domain)
		my $pk_fh = IO::File->new(">".$protein_kinase_seq) || die "Can not open protein kinase sequence file: $protein_kinase_seq\n";
		foreach my $pid (sort keys %pkinase_id)
		{
			if (defined $seq_hash{$pid}) 
			{
				print $pk_fh ">".$pid."\n".$seq_hash{$pid}."\n";
			}
			else
			{
				print "Error! no sequences match to this id $pid\n";
			}
		}
		$pk_fh->close;

		# Step 3.3 Get Protein Kinases Classification using hmmscan
		# Step 3.3.1 hmmscan
		my $tmp_plantsp_hmm_result = "$temp_dir/temp_plantsp_hmm_result";
		my $tmp_rkd_hmm_result 	   = "$temp_dir/temp_rkd_hmm_result";
		my $tmp_shiu_hmm_result    = "$temp_dir/temp_shiu_hmm_result";

		my $plantsp_hmmscan_command = $bin_dir."/hmmscan --acc --notextw --cpu $cpus -o $tmp_plantsp_hmm_result $plantp_hmm_3 $protein_kinase_seq";
		my $rkd_hmmscan_command     = $bin_dir."/hmmscan --acc --notextw --cpu $cpus -o $tmp_rkd_hmm_result     $rkd_hmm_3    $protein_kinase_seq";
		my $shiu_hmmscan_command    = $bin_dir."/hmmscan --acc --notextw --cpu $cpus -o $tmp_shiu_hmm_result    $shiu_hmm_3   $protein_kinase_seq";

		print $plantsp_hmmscan_command if $debug == 1;
		print $rkd_hmmscan_command if $debug == 1;
		print $shiu_hmmscan_command if $debug == 1;

		unless (-s $tmp_plantsp_hmm_result) { system($plantsp_hmmscan_command) && die "Error at hmmscan command: $plantsp_hmmscan_command\n"; }
		#unless (-s $tmp_rkd_hmm_result)  { system($rkd_hmmscan_command) && die "Error at hmmscan command: $rkd_hmmscan_command\n"; }	
		unless (-s $tmp_shiu_hmm_result) { system($shiu_hmmscan_command) && die "Error at hmmscan command: $shiu_hmmscan_command\n"; }
		
		# Step 3.3.2 parse hmmscan result
		my ($hmm3_simple_result, $hmm3_simple_align) = parse_hmmscan_result($tmp_plantsp_hmm_result);
		#my ($hmm3_rkd_result, $hmm3_rkd_align) = parse_hmmscan_result($tmp_rkd_hmm_result);
		my ($hmm3_shiu_result, $hmm3_shiu_align) = parse_hmmscan_result($tmp_shiu_hmm_result);

		# Step 3.3.3 get classification info base simple hmminfo, means get best hits of simple result, then add annotation and output alignment file
		my %pkinases_cat = get_classification($hmm3_simple_result);
		my %shiu_cat = get_classification($hmm3_shiu_result);
		#my %rkd_cat = get_classification($hmm3_rkd_result);

		#################################################
		# output PlantsP alignment and classification 	#
		#################################################
		my $protein_kinase_aln1 = $output_dir."/".$input_seq."_pkaln1";
		my $protein_kinase_cat1 = $output_dir."/".$input_seq."_pkcat1";
	
		my $ca_fh1 = IO::File->new(">".$protein_kinase_cat1) || die "Can not open protein kinase sequence file: $protein_kinase_cat1 $!\n";
		my $al_fh1 = IO::File->new(">".$protein_kinase_aln1) || die "Can not open protein kinase sequence file: $protein_kinase_aln1 $!\n";

		foreach my $pid (sort keys %pkinases_cat)
		{
			if (defined $pkinase_aln{$pid})
			{
				print $al_fh1 $pkinase_aln{$pid};
			}
			else
			{
				die "Error! Do not have alignments in hmm3 parsed result\n";
			}
			delete $pkinase_id{$pid};	
		}

		foreach my $pid (sort keys %pkinase_id)
		{
			print $ca_fh1 $pid."\tPPC:1.Other\n";

			if (defined $pkinase_aln{$pid})
			{
				print $al_fh1 $pkinase_aln{$pid};
			}
			else
			{
				die "Error! Do not have alignments in hmm3 parsed result\n";
			}
		}
		$al_fh1->close;

		# Step 3.3.4 find WNK1 domain in 4.1.5 cat;
		# $input, $hmm, $score, $cat_id, $new_cat_id
		%pkinases_cat = get_wnk1(\%pkinases_cat, "$dbs_dir/wnk1_hmm_domain/WNK1_hmm" , "30" ,"PPC:4.1.5", "PPC:4.1.5.1");
		$$pkid_des{"PPC:4.1.5.1"} = "WNK like kinase - with no lysine kinase";

		%pkinases_cat = get_wnk1(\%pkinases_cat, "$dbs_dir/mak_hmm_domain/MAK_hmm" , "460.15" ,"PPC:4.5.1", "PPC:4.5.1.1");
		$$pkid_des{"PPC:4.5.1.1"} = "Male grem cell-associated kinase (mak)";
	
		foreach my $pid (sort keys %pkinases_cat) {
			print $ca_fh1 $pid."\t".$pkinases_cat{$pid}."\t".$$pkid_des{$pkinases_cat{$pid}}."\n";
		}
		$ca_fh1->close;


		#################################################
                # output Shiu alignment and classification   	#
                #################################################
                my $protein_kinase_aln2 = $output_dir."/".$input_seq."_pkaln2";
                my $protein_kinase_cat2 = $output_dir."/".$input_seq."_pkcat2";

                my $ca_fh2 = IO::File->new(">".$protein_kinase_cat2) || die "Can not open protein kinase sequence file: $protein_kinase_cat2 $!\n";
                my $al_fh2 = IO::File->new(">".$protein_kinase_aln2) || die "Can not open protein kinase sequence file: $protein_kinase_aln2 $!\n";
		foreach my $pid (sort keys %shiu_cat) { print $ca_fh2 $pid."\t".$shiu_cat{$pid}."\n"; }
		print $al_fh2 $hmm3_shiu_align;
		$ca_fh2->close;
		$al_fh2->close;

		#################################################
		# output rkd alignment and classification       #
		#################################################
		my $protein_kinase_aln3 = $output_dir."/".$input_seq."_pkaln3";
		my $protein_kinase_cat3 = $output_dir."/".$input_seq."_pkcat3";

		#my $ca_fh3 = IO::File->new(">".$protein_kinase_cat3) || die "Can not open protein kinase sequence file: $protein_kinase_cat3 $!\n";
		#my $al_fh3 = IO::File->new(">".$protein_kinase_aln3) || die "Can not open protein kinase sequence file: $protein_kinase_aln3 $!\n";
		#$ca_fh3->close;
		#$al_fh3->close;

		# report protein kinase number
		print $pk_seq_num." protein kinases were identified.\n";
    	}
	else
	{
		print "No protein kinase was identified.\n";
	}
}

#################################################################
# kentnf : subroutines						#
#################################################################

=head2 parse_format_result

 Function: filter hmmscan parsed result, if socre >= GA score or evalue <= 1e-3, it will be seleted.

 Input: 1. formated result of hmmscan: query name; hit name;score; evalue; 
	2. gathering score hash, PF id ; GA score; 
                                 key      vaule

 Return: hash1 -- key: seq_id,    value: domain_id1 \t domain_id2 \t ... \t domain_idn
 Return: hash2 -- key: domain_id, value: PfamID
 Retrun: hash3 -- key: domain_id, value: SeqID \t PfamID \t 
=cut
sub parse_format_result
{
	my ($in_file, $ga_score_hash) = @_;

	my %out_hash; my %hsp_hit_id; my %hsp_detail;

	my @in_file = split(/\n/, $in_file);

	my $len = length(scalar(@in_file)); 

	my $uid = 0;
	
	for(my $in=0; $in<@in_file; $in++)
	{
		#################################################
		# filter HSP detail result with GA or e-value	#
		#################################################
		chomp($in_file[$in]);
		my @fmm = split(/\t/, $in_file[$in]);

		$fmm[1] =~ s/\..*//; #this is Pfam or self-build domain ID

		my $valued = 0; my $gaScore;

		if (defined $$ga_score_hash{$fmm[1]})
		{
			$gaScore = $$ga_score_hash{$fmm[1]};

			if ( $fmm[9] >= $gaScore ) { $valued = 1; }
		}
		else
		{ 
			if ($fmm[10] <= 1e-3) { $valued = 1; }
		}

		#################################################
		# if valued means we select this domain info	#
		# then creat three hashes base on this		#
		#################################################
		if ($valued == 1)
		{
			$uid++; my $zero = "";
			my $rlen = $len-length($uid);
			for(my $l=0; $l<$rlen; $l++)
			{
				$zero.="0";
			}

			$hsp_detail{$zero.$uid} = $in_file[$in];
			$hsp_hit_id{$zero.$uid} = $fmm[1];
			
			if (defined $out_hash{$fmm[0]})
			{
				$out_hash{$fmm[0]}.= "\t".$zero.$uid;
			}
			else
			{
				$out_hash{$fmm[0]}.= $zero.$uid;
			}
		}
	}	
	return (\%out_hash, \%hsp_hit_id, \%hsp_detail);
}

=head2 identify_domain
 identify Transcription Factors conde + finde Protein Kinases domains 
=cut
sub identify_domain
{
	my ($all_hits, $all_detail, $rule, $transposase) = @_;

	my $alignment = "";
	my $family = "";

	# 1. parse hmmscan result
	# my ($all_hits, $all_detail) = parse_hmmscan_result($hmm_result);

	# 2. Using GA score and e-value filter the all hits
	# $pid_did    -- key: protein sequence id;  value: domain order id
	# $hsp_hit    -- key: domain order id;      value: PfamID
	# $hsp_detail -- key: domain order id;      value: aligment_detail
	my $ga_hash; my %rules;
	my ($pid_did, $hsp_hit, $hsp_detail) = parse_format_result($all_detail, $ga_hash);

	# 3. Parse rule list file to produce rules
	my ($required_pack, $forbidden_pack, $rule_mode) = parse_rule($rule);
	my %required = %$required_pack; my %forbidden = %$forbidden_pack; my %rule_mode = %$rule_mode;

	my %required_domain = get_domain_id($rule, 2);
	print "\nThere are ".scalar(keys(%required_domain))." required domains for TF classification\n" if $debug == 1;

	# 4. Classify the proteins and output the results to files;
    	foreach my $protein_id (sort keys %$pid_did)
    	{

		foreach my $rid (sort keys %rules)
		{

		}
		
		my $is_family = 0;

		my @did = split(/\t/, $$pid_did{$protein_id});

		my $convert_domain = "";	# convert uid to domain id for one hit;
		my $hit_alignment = "";		# get alignment for one hit;

		for(my $ci=0; $ci<@did; $ci++)
		{
			my $c_domain_id = $$hsp_hit{$did[$ci]};
			$convert_domain = $convert_domain."\t".$c_domain_id;

			my $hsp_alignment = $$hsp_detail{$did[$ci]};
			$hit_alignment.=$hsp_alignment."\n";
		}
		$convert_domain =~ s/^\t//;

		my @convert_domain = split(/\t/, $convert_domain);

		# checking transposase
		my $has_transposase = 0;
		foreach my $domain_id ( @convert_domain )
		{
			if (defined $$transposase{$domain_id}) { $has_transposase = 1; }
		}

		if ($has_transposase == 1) 
		{
			print "Protein $protein_id was removed for including transposase: $convert_domain\n";
			next; 
		}




		# checking family
		for(my $di=0; $di<@did; $di++)
		{
			my $domain_id = $$hsp_hit{$did[$di]};  # convert uid to domain id

			if (defined $required_domain{$domain_id} && $is_family == 0 )
			{
				my @familys = split(/\t/, $required_domain{$domain_id});

				foreach my $fn (@familys)
				{
					my @this_required = split(/#/, $required{$fn});

					my @this_forbidden;

					if ( $forbidden{$fn} )
					{
						@this_forbidden = split(/#/, $forbidden{$fn});
					}

					my $mode_r = $rule_mode{$fn};	
	
					$is_family = check_family(\@convert_domain, \@this_required, \@this_forbidden, $mode_r);

					if ($is_family == 1) 
					{
						if ($fn eq "ARR-B_A") { $fn = "ARR-B"; }
				 
						$family.=$protein_id."\t".$fn."\n";
						$alignment.= $hit_alignment;
						last; 
					}
				}
			}

			if ($is_family == 1) { last; }
		}	

	    	unless ($is_family == 1) 
	    	{
			#################################################
			# to check myb-related				#
			#################################################
			my $is_a = 0; my $not_is_a = 0;
			for (my $dii=0; $dii<@did; $dii++)
			{
				if (    $$hsp_hit{$did[$dii]} eq "PF00249" ) { $is_a = 1; }
				if (    $$hsp_hit{$did[$dii]} eq "PF01388" ||
					$$hsp_hit{$did[$dii]} eq "PF00072" ||
					$$hsp_hit{$did[$dii]} eq "PF00176" ||
					$$hsp_hit{$did[$dii]} eq "G2-like" ||
					$$hsp_hit{$did[$dii]} eq "Trihelix" )
				{ $not_is_a = 1; }
			}

			if ($is_a == 1 && $not_is_a == 0)
			{
				$family.=$protein_id."\t"."MYB\n";
				$alignment.= $hit_alignment;
			}

			#################################################
			# to check orphans				#
			#################################################
			my $is_orphans = 0;
			for(my $dii=0; $dii<@did; $dii++)
			{
				if (
					$$hsp_hit{$did[$dii]} eq "PF06203" || 
					$$hsp_hit{$did[$dii]} eq "PF00643" || 
					$$hsp_hit{$did[$dii]} eq "PF00072" || 
					$$hsp_hit{$did[$dii]} eq "PF00412" ||
					$$hsp_hit{$did[$dii]} eq "PF02671" || 
					$$hsp_hit{$did[$dii]} eq "PF03925" || 
					$$hsp_hit{$did[$dii]} eq "PF09133" || 
	                                $$hsp_hit{$did[$dii]} eq "PF09425" 
				   )
				{
					$is_orphans = 1;
				}
			}

			if ($is_orphans == 1)
			{
				$family.=$protein_id."\t"."Orphans\n";
				$alignment.= $hit_alignment;
			}
	 	}
    	}
	return ($alignment, $family);
}

=head2 compare_a_b


=cut
sub compare_a_b
{
        my ($ha, $hb) = @_;

        my %ha = %$ha; my %hb = %$hb;

        my %hash1; my %hash2; my %match;

        foreach my $ida (sort keys %ha)
        {
                my $aa = $ida."\t".$ha{$ida};
                $hash1{$aa} = 1;
        }

        foreach my $idb (sort keys %hb)
        {
                my $bb = $idb."\t".$hb{$idb};
                $hash2{$bb} = 1;
        }

        foreach my $key1 (sort keys %hash1)
        {
                if (defined $hash2{$key1})
                {
                        $match{$key1} = 1;
                        delete $hash1{$key1};
                        delete $hash2{$key1};
                }
        }

        return (\%match, \%hash1, \%hash2);
}

=head2 aln_to_hash
=cut
sub aln_to_hash
{
	my $aln_detail = shift;

	my $ga_hash;

	my %aln_hash;

	my @line = split(/\n/, $aln_detail);

	for(my $i=0; $i<@line; $i++)
	{
		my @a = split(/\t/, $line[$i]);

		# filte the aligment by GA score
		my $pfam_id = $a[1];
		$pfam_id =~ s/\..*//;

		if ( $a[9] >= $$ga_hash{$pfam_id} )
		{
			#print $a[9]."\t$pfam_id\t".$$ga_hash{$pfam_id}."\n";
			if (defined $aln_hash{$a[0]})
			{
				$aln_hash{$a[0]}.=$line[$i]."\n";
			}
			else
			{
				$aln_hash{$a[0]} = $line[$i]."\n";
			}
		}
	}
	return %aln_hash;
}

#################################################################
# kentnf: true subroutine					#
#################################################################
=head2
 load_rule -- load rule to hash
 # this rule is update on 20141103
 # Description of each column
 # 1. ID of rule, the rule with small order number will have high priority
 # 2. name of the rule -- subfamily
 # 3. parent name of the rule -- superfamily
 # 4. required domain
 # 5. auxiiary domain
 # 6. forbidden domain
 # 7. type
 # 8. description
=cut
sub load_rule
{
	my $rule_file = shift;
	
	my %rule_obj;
	my ($id, $name, $family, $required, $auxiiary, $forbidden, $type, $desc);
	my $fh = IO::File->new($rule_file) || die $!;
	while(<$fh>)
	{
		chomp;
		next if $_ =~ m/^#/;
		
		if ($_ =~ m/^\/\//) 	# put current rule to hash, and start a new rule
		{
			die "[ERR]undef rule member $id\n" unless($id && $name && $family && $required && $auxiiary && $forbidden && $type && $desc);
			$rule_obj{$id}{'name'} = $name;
			$rule_obj{$id}{'family'} = $family;
			$rule_obj{$id}{'required'}  = parse_domain_rule($required);
			$rule_obj{$id}{'auxiiary'}  = parse_domain_rule($auxiiary);
			$rule_obj{$id}{'forbidden'} = parse_domain_rule($forbidden);
			$rule_obj{$id}{'type'} = $type;	
			$rule_obj{$id}{'desc'} = $desc;
			($id, $name, $family, $required, $auxiiary, $forbidden, $type, $desc) = ('', ''. '', '', '', '', '', '');
		} elsif ($_ =~ m/^ID:/) {
			$id = $_; $id =~ s/^ID://;
		} elsif ($_ =~ m/^Name:/) {
			$name = $_; $name =~ s/^Name://;
		} elsif ($_ =~ m/^Family:/) {
			$family = $_; $family =~ s/^Family://;
		} elsif ($_ =~ m/^Required:/) {
			$required = $_; $required =~ s/^Required://;
		} elsif ($_ =~ m/^Auxiiary:/) {
			$auxiiary = $_; $auxiiary =~ s/^Auxiiary://;
		} elsif ($_ =~ m/^Forbidden:/) {
			$forbidden = $_; $forbidden =~ s/^Forbidden://;
		} elsif ($_ =~ m/^Type:/) {
			$type = $_; $type =~ s/^Type://;
		} elsif ($_ =~ m/^Desc:/) {
			$desc = $_; $desc =~ s/^Desc://;
		} else {
			next;
		}
	}
	$fh->close;
	return %rule_obj;
}

=head
 parse_domain_rule: parse domain rules

 Description of domain rules
 PF00001 : domain ID, without version 
 #2 : number of requred domains
 '-' : and
 ':' : or members
 ';' : or rules
 '()' : priority

 example 1: PF00001#2-PF00002#1
 mean this rule require 2 of PF00001 domain and one of PF00002

 example 2; PF00001#2;PF00002#1
 mean this rule require 2 of PF00001 domain or one of PF00002

 example 3; PF00001#2;PF00002#1-PF00003#1:PF00004#1
 requred hash: 	1. PF00001 and PF00001
		2. PF00002 and PF00003
		3. PF00002 and PF00004
=cut
sub parse_domain_rule 
{
	my $domain_rule = shift;

	return $domain_rule if $domain_rule eq 'NA';

	my %domain_combination = ();			# key, array of domains for the rule.
	my @r = split(/;/, $domain_rule);
	foreach my $r ( @r ) {

		# hash for sub domain combination
		# key, array of domains for the rule, sub of domain_combination, equal to domain_combination when @r == 1;
		my %domain_combination_sub = ();

		my @m = split(/--/, $r);
		foreach my $m ( @m ) {

			my @p = split(/:/, $m);
			die "[ERR] $m\n" if scalar(@p) < 1;

			# for the first domain combination sub
			if (scalar keys %domain_combination_sub == 0) {
				foreach my $p ( @p ) {
					my $domain_id = split_domain_num($p);
					$domain_combination_sub{$domain_id} = 1;
				}
				next;
			}

			# for the single domain in this member
			if (scalar @p == 1) {
				my $domain_id = split_domain_num($p[0]);
				foreach my $com (sort keys %domain_combination_sub) {
					delete $domain_combination_sub{$com};		# remove old record
					$com.= ",$domain_id";				# add new domain to old for new record
					$domain_combination_sub{$com} = 1;		# put new reacord to hash
				}
				next;
			}

			# for the multiply domains in this member
			if (scalar @p > 1) {
				foreach my $com (sort keys %domain_combination_sub) {
					delete $domain_combination_sub{$com};		# remove old record
					foreach my $p (@p) {
						my $domain_id = split_domain_num($p);	
						my $new_com = $com.",$domain_id";	# add new domain to old for new record
						$domain_combination_sub{$new_com} = 1;	# put new reacord to hash
					}
				}
			}
		}

		# put sub domain combination to domain combination
		foreach my $com (sort keys %domain_combination_sub) {
			$domain_combination{$com} = 1;
		}
	}
	return \%domain_combination;
}

sub split_domain_num
{
	my $domain_num = shift;
	# print "x:$domain_num\n";

	die "[ERR]domain num format 1 $domain_num\n" unless $domain_num =~ m/#/;
	my @a = split(/#/, $domain_num);
	die "[ERR]domain num format 2 $domain_num\n" unless (scalar @a == 2);
	die "[ERR]domain num format 3 $domain_num\n" unless $a[1] > 0;
	my $domain_id = '';
	for (my $i=0; $i<$a[1]; $i++) {
		$domain_id.=",".$a[0];
	}
	$domain_id =~ s/^,//;
	return $domain_id;
}

=head2
 print_rule -- print rule in hash for debug
=cut
sub print_rule
{
	my $rule_pack = shift;
	my %rule = %$rule_pack;
	foreach my $id (sort keys %rule) {
	        print $id."\n";
	        print $rule{$id}{'name'},"\n";
	        print $rule{$id}{'family'},"\n";
	        print $rule{$id}{'type'},"\n";
	        print $rule{$id}{'desc'},"\n";

	        print "Required:\n";
	        foreach my $d (sort keys %{$rule{$id}{'required'}}) {
	                print $d."\n";
	        }

	        print "Auxiiary:\n";
		foreach my $d (sort keys %{$rule{$id}{'auxiiary'}}) {
	                print $d."\n";
	        }

		print "Forbidden:\n";
        	foreach my $d (sort keys %{$rule{$id}{'forbidden'}}) {
                	print $d."\n";
        	}
	}	
	exit;
}

=head2
 load_ga_cutoff: load GA cutoff score to hash
=cut
sub load_ga_cutoff 
{
	my ($pfam_db, $correct_ga) = @_;


	# put GA cutoff to hash
	# key: pfam ID 
	# value: GA score
	my %ga_cutoff;
	my ($pfam_id, $ga_score) = ('', '');
	my $fh1 = IO::File->new($pfam_db) || die $!;
	while(<$fh1>)
	{
		chomp;
		if ($_ =~ m/^ACC\s+(\S+)/) {
			$pfam_id = $1;
			$pfam_id =~ s/\..*//;
		} elsif ($_ =~ m/^GA\s+(\S+)/) {
			$ga_score = $1;
		} elsif ($_ eq "//") {
			print "[ERR]no pfam id\n" unless $pfam_id;
			print "[ERR]no ga score $pfam_id\n" unless $ga_score;
			$ga_cutoff{$pfam_id} = $ga_score;
			$pfam_id = '';
			$ga_score = '';
		} else {
			next;
		}	
	}
	$fh1->close;

	# correct GA cutoff
	my $fh2 = IO::File->new($correct_ga) || die $!;
	while(<$fh2>)
	{
		chomp;
		my @a = split(/\t/, $_);
		($pfam_id, $ga_score) = @a;
		$pfam_id =~ s/\..*//;
		die "[ERR]no correct pfam id  $_\n" unless defined $ga_cutoff{$pfam_id};
		die "[ERR]no correct ga score $_\n" unless $ga_score;
		$ga_cutoff{$pfam_id} = $ga_score;
	}
	$fh2->close;

	# print scalar(keys(%ga_cutoff)). "record has GA score\n";
	return %ga_cutoff;
}

=head2
 itak_tf_identify -- identify transcription factors

AT1G01140.1   PF00069.20      19      274     1       260     YEMGRTLGEGSFAKVKYAKNTVTGDQAAIKILDREKVFRHKMVEQLKrEISTMKLIKHPNVVEIIEVMASKTKIYIVLEL
VNGGELFDKIAQQGRLKEDEARRYFQQLINAVDYCHSRGVYHRDLKPENLILDANGVLKVSDFGLSAFSrqVREDGLLHTACGTPNYVAPEVLSDKGYDGAAADVWSCGVILFVLMAGYLPFDEP---NLMTLYKRICKAEFSC
PPWFS----QGAKRVIKRILEPNPITRISIAELLEDEWF ye +++lG+Gsf+kV  ak+  tg++ A+Kil++e+  + k  ++l+ E++ +k ++Hpn+v+++ev+ +k+++y+vle+v+gg+lfd ++++g+l+e+e++++
++q++++++y+Hs+g++HrDLKpeN++ld +g+lk++DFGl+      ++++ l+t +gt++Y+APEvl ++ ++++++DvWs+Gvil+ l+ g lpf++    + + l+++i k + + + + s    + +k +ik++le++p
 +R++++e+l+++w+ yelleklGsGsfGkVykakekktgkkvAvKilkkeeekskkektalr.ElkilkklnHpnivkllevfeekdelylvleyveggdlfdllkkkgklseeeikkialqilegleylHsngiiHrDLKpe
NiLldekgelkiaDFGlakkl..eksseklttlvgtreYmAPEvllkakeytkkvDvWslGvilyelltgklpfsgeseedqlelirkilkkkleedepkssskseelkdlikkllekdpakRltaeeilkhpwl 241.8  6
.4e-72  Protein kinase domain   448

=cut
sub itak_tf_identify 
{
	my ($hmmscan_hit, $hmmscan_detail, $ga_cutoff, $tf_rule) = @_;

	chomp($hmmscan_hit);
	chomp($hmmscan_detail);

	# create hash for result
	# key: query id of protein
	# value: tid of TF
	my %qid_tid;

	# put hits domains to hash : query_hits
	# key: query ID
	# value: array of hmm hits
	# * filter hits with lower score using GA cutoff
	my %query_hits;
	my ($query_id, $pfam_id, $score, $evalue);
	my @a = split(/\n/, $hmmscan_hit);
	foreach my $a (@a) 
	{
		my @b = split(/\t/, $a);
		#AT1G01140.1     PF00069.20      241.8   6.4e-72
		($query_id, $pfam_id, $score, $evalue) = @b;
		$pfam_id =~ s/\..*// if $pfam_id =~ m/^PF/;
		die "[ERR]undef GA score for $pfam_id\n" unless defined $$ga_cutoff{$pfam_id};
		next if $score < $$ga_cutoff{$pfam_id};

		if (defined $query_hits{$b[0]}) {
			$query_hits{$b[0]}.="\t".$pfam_id;
		} else {
			$query_hits{$b[0]} = $pfam_id;
		}
	}

	# compare query_hits with rules
	foreach my $qid (sort keys %query_hits)
	{
		my $hits = $query_hits{$qid};
		# print "$qid\t$hits\n";
		my @rule_id = compare_rule($hits, $tf_rule);

		if (scalar @rule_id > 0) {
			foreach my $tid ( @rule_id ) {
				$qid_tid{$qid} = $tid;
			}
		}
	}

	return %qid_tid;
}

=head2
 compare_rule : compare
 # input is filtered hmm_hit and packed rules
=cut
sub compare_rule
{
	my ($hmm_hit, $rule_pack) = @_;
	
	my %rule = %$rule_pack; # unpack the rule

	# compare the hits with rules, including required, auxiiary, and forbidden domains
	# the comparison will return match status: 
	# 0, do not match
	# 1, partially match
	# 2, full match
	# the assign family to each protein according hits and ruls
	my @rule_id;

	my @hits = split(/\t/, $hmm_hit);

	foreach my $rid (sort keys %rule) {
		my $required_h = $rule{$rid}{'required'};
		my $auxiiary_h = $rule{$rid}{'auxiiary'};
		my $forbidden_h = $rule{$rid}{'forbidden'};

		# compare forbidden with hits
		my $f_status = 0;
		if ($forbidden_h ne 'NA') {
			foreach my $forbidden (sort keys %$forbidden_h) {
				my @f = split(/,/, $forbidden);
				my $match_status = compare_array(\@hits, \@f);
				$f_status = 1 if $match_status > 0;
			}
		}
		next if $f_status == 1;

		# compare required with hits
		my $r_status = 0;
		foreach my $required (sort keys %$required_h) {
			my @r = split(/,/, $required);
			my $match_status = compare_array(\@hits, \@r);
			$r_status = 1 if $match_status == 2;
		}

		# compare auxiiary with hits
		my $a_status = 0;
		if ($auxiiary_h ne 'NA') {
			foreach my $auxiiary (sort keys %$auxiiary_h) {
				my @a = split(/,/, $auxiiary);
				my $match_status = compare_array(\@hits, \@a);
				$a_status = 1 if $match_status == 2;
			}
			push(@rule_id, $rid) if ($r_status == 1 && $a_status == 1);

		} else {
			push(@rule_id, $rid) if $r_status == 1;
		}
	}
	return @rule_id;
}

# sub for compare rule
sub compare_array
{
	my ($array_A, $array_B) = @_;
	my @a = @$array_A;
	my @b = @$array_B;	

	# convert array to hash
	my %ua; my %ub;
	foreach my $a (@a) {
		if (defined $ua{$a}) { $ua{$a}++; } else { $ua{$a} = 1; }
	}

	foreach my $b (@b) {
		if (defined $ub{$b}) { $ub{$b}++; } else { $ub{$b} = 1; }
	}
	
	# compare two hash
	my $match = 0;
	foreach my $b (sort keys %ub) {
		if (defined $ua{$b} && $ua{$b} >= $ub{$b}) {
			$match++;
		}
	}

	# retrun match status
	# 0, do not match
	# 1, partially match
	# 2, full match	
	my $match_status = 0;
	$match_status = 1 if $match > 0;
	if ( $match == scalar(keys(%ub)) ) {
		$match_status = 2;
	}

	return $match_status; 
}

=head2
 itak_tf_write_out: write out tf result to output file
=cut
sub itak_tf_write_out
{
	my ($qid_tid, $seq_info, $hmmscan_detail_1, $tf_rule, $output_sequence, $output_alignment, $output_classification) = @_;

	# put hmmscan_detail to hash
	my %q_detail;
	chomp($hmmscan_detail_1);
	my @a = split(/\n/, $hmmscan_detail_1);
	foreach my $a (@a) {
		my @b = split(/\t/, $a);
		if (defined $q_detail{$b[0]}) {
			$q_detail{$b[0]}.= $a."\n";
		} else {
			$q_detail{$b[0]} = $a."\n";
		}
	}

	my $out1 = IO::File->new(">".$output_sequence) || die $!;
	my $out2 = IO::File->new(">".$output_alignment) || die $!;
	my $out3 = IO::File->new(">".$output_classification) || die $!; 

	foreach my $qid (sort keys %$qid_tid) {
		
		my $tid     = $$qid_tid{$qid};
		my $tname   = $$tf_rule{$tid}{'name'};
		my $tfamily = $$tf_rule{$tid}{'family'};
		my $type    = $$tf_rule{$tid}{'type'};
		my $desc    = $$tf_rule{$tid}{'desc'};
		my $qseq    = $$seq_info{$qid}{'seq'};
		my $align   = $q_detail{$qid};

		print $out1 ">$qid [$type]$tname:$tfamily--$desc\n$qseq\n";
		print $out2 $align;
		print $out3 "$qid\t$tname\t$type\t$tfamily\n";
	}
	$out1->close;
	$out2->close;
	$out3->close;
}

=head2 
 itak_pk_classify -- classify pkinase
=cut
sub itak_pk_classify
{
        my $hmmscan_hit = shift;
	chomp($hmmscan_hit);
	my @hit_line = split(/\n/, $hmmscan_hit);

	# put hmmscan hit to hash
	# %hit: key: protein seq ID 
	#       value: family id
	# %score: key: protein seq ID
	# 	  value: best hit score for domain
        my %hit; my %score;

	foreach my $line (@hit_line) {
		my @a = split(/\t/, $line);
		if (defined $hit{$a[0]}) {
			if ($a[2] > $score{$a[0]}) {
				$hit{$a[0]} = $a[1];
				$score{$a[0]} = $a[2];
			}
		} else {
			$hit{$a[0]} = $a[1];
			$score{$a[0]} = $a[2];
		}
	}

        return %hit;
}

=head2
 pk_to_hash -- load plantsp family description to hash
=cut
sub pk_to_hash
{
        my $file = shift;
        my %hash;
        my $pfh = IO::File->new($file) || die "Can not open protein kinase description file: $file $!\n";
        while(<$pfh>)
        {
                chomp;
                my @pm = split(/\t/, $_, 2);
                $hash{$pm[0]} = $pm[1];
        }
        $pfh->close;
        return (\%hash);
}

=head2
 seq_to_hash: put seq info to hash
=cut
sub seq_to_hash
{
	my $input_file = shift;
	my %seq_info;
	my $in = Bio::SeqIO->new(-format=>'fasta', -file=>$input_file);
	while(my $inseq = $in->next_seq)
	{
		$seq_info{$inseq->id}{'alphabet'} = $inseq->alphabet;
		$seq_info{$inseq->id}{'seq'} = $inseq->seq;
	}
	return %seq_info	
}

=head2
 run_cmd : run command
=cut
sub run_cmd
{
	my $cmd = shift;
	print "[ERR]no command: $cmd\n" and exit unless $cmd;
	print $cmd."\n" and return(1) if $debug;
	system($cmd) && die "[ERR]cmd: $cmd\n";
}

=head2
 usage : print usage
=cut
sub usage
{
	my $version = shift;
	my $usage = qq'
VERSION: $version
USAGE:  perl $0 -t [tool] 
	
	database	prepare database files for identification
	identify	identify TFs and PKs

';
	print $usage;
	exit;
}




