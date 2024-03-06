### Before deploying on alpha:
### Ask bob for help with:
### change to config write out for sample level metadata (primers and dates)
### update barcodes path to be a variable?
### Nicole changes:
### change job_failed_exists and  save_output_files so it uploads everything
### change jobs_failed.txt to 'job_summary.txt' and only use job_failed.txt if all samples fail
### add samtools flag stats
### add script to make job summary table (that made the 100 samples table)
###

#
# App wrapper for the SARS2Waterwater analysis pipeline.
# This runs snakemake files for the BV-BRC's sars2-onecodex pipeline and Freyja
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;
use Bio::KBase::AppService::AppConfig qw(metagenome_dbs);
use File::Slurp;
use IPC::Run;
use Cwd qw(abs_path getcwd);
use File::Path 'make_path';
use strict;
use Data::Dumper;
use File::Basename;
use File::Temp;
use JSON::XS;
use Getopt::Long::Descriptive;

my $app = Bio::KBase::AppService::AppScript->new(\&run_app, \&preflight);

$app->run(\@ARGV);

sub run_app
{
    my($app, $app_def, $raw_params, $params) = @_;
	process_read_input($app, $params);
}

sub job_failed_exists {
    my($app, $output) = @_;
    my $job_failed_txt = shift;

    if (-e $job_failed_txt) {
        print "File '$job_failed_txt' exists. Uploading to workspace \n";
         my @cmd = ("p3-cp", "ws:" . $app->result_folder);
	    print STDERR "saving files to workspace... @cmd\n";
	    my $ok = IPC::Run::run(\@cmd);
	    if (!$ok)
	    {
		warn "Error $? copying output with @cmd\n";
	    }
        return 1;  # File exists
    } else {
        print "File '$job_failed_txt' does not exist. Uploading all results in the output directory \n";
        save_output_files($app, $output);
        return 0;  # File does not exist
    }
}


sub process_read_input
{
    my($app, $params) = @_;

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params, 1);
    
    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);
    
    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    
    my $top = getcwd;
    my $staging = "$top/staging";
    my $output = "$top/output";
    make_path($staging, $output);
    $readset->localize_libraries($staging);
    $readset->stage_in($app->workspace);

    #
    # Modify the parameters to remove any SRA libraries and instead
    # use the SE & PE lists from the readset.
    #

    my $nparams = { single_end_libs => [], paired_end_libs => [], srr_libs => [] };;

    $readset->visit_libraries(sub { my($pe) = @_;
				    my $lib = {
					read1 => abs_path($pe->{read_path_1}),
					read2 => abs_path($pe->{read_path_2}),
					(exists($pe->{sample_id}) ? (sample_id => $pe->{sample_id}) : ())
					};
				    push(@{$nparams->{paired_end_libs}}, $lib);
				},
			      sub {
				  my($se) = @_;
				  my $lib = {
				      read => abs_path($se->{read_path}),
				      (exists($se->{sample_id}) ? (sample_id => $se->{sample_id}) : ())
				      };
				  push(@{$nparams->{single_end_libs}}, $lib);
			      },
			     );
    $params->{$_} = $nparams->{$_} foreach keys %$nparams;

    # If there is  a sample metadata file given copy it into the disk
    # Access the value for "test_var_1"
    my $sample_metadata_path = $params->{"sample_metadata_csv"};
    my $staging_sample_metadata_path = "0";
    # If a path is provided copy the file to disc and update path 
    if ($sample_metadata_path eq "0") {
        print "sample metadata path is equal to 0\n";

    } else {
        print "sample metadata is is provided\n copying to disc";
        my @cmd = ("p3-cp","ws:$sample_metadata_path", "$staging");
	    print STDERR "copying sample metadata file to staging dir @cmd\n";
	    my $ok = IPC::Run::run(\@cmd);
	    if (!$ok)
	    {
		warn "Error $? copying metadata file failed with @cmd\n";
	    }
        if ($sample_metadata_path =~ m|/([^/]+)\.csv$|) {
            $staging_sample_metadata_path = "$staging/$1.csv";
        } else {
            print "No match found\n";
        }
    }

    print STDERR "Starting the config json....\n";
    my $json_string = encode_json($params);

    #
    # Create json config file for the execution of this workflow.
    # If we are in a production deployment, we can find the workflows
    # by looking in $KB_TOP/workflows/app-name
    # Otherwise they are in the module directory; this is indicated
    # by the value of $KB_MODULE_DIR (note this is set for both
    # deployed and dev-container builds; the deployment case
    # is determined by the existence of $KB_TOP/workflows)
    #

    my %config_vars;
    # temp barcode path
    my $barcodes_path = "/vol/bvbrc/production/application-backend/SARS2WasteWater/2024-03-06/usher_barcodes.csv";
    my $curated_linages = "/vol/bvbrc/production/application-backend/SARS2WasteWater/2024-03-06/curated_lineages.json";
    my $wf_dir = "$ENV{KB_TOP}/workflows/$ENV{KB_MODULE_DIR}";
    if (! -d $wf_dir)
    {
	$wf_dir = "$ENV{KB_TOP}/modules/$ENV{KB_MODULE_DIR}/workflow";
    }
    -d $wf_dir or die "Workflow directory $wf_dir does not exist";

    #
    # Find snakemake. We need to put this in a standard location in the runtime but for now
    # use this.
    #
    my $snakemake = "$ENV{KB_RUNTIME}/artic-ncov2019/bin/snakemake";
    $config_vars{barcodes_path} = $barcodes_path;
    $config_vars{curated_linages} = $curated_linages;
    $config_vars{staging_sample_metadata_path} = $staging_sample_metadata_path;
    $config_vars{workflow_dir} = $wf_dir;
    $config_vars{input_data_dir} = $staging;
    $config_vars{output_data_dir} = $output;
    $config_vars{snakemake} = $snakemake;
    $config_vars{cores} = $ENV{P3_ALLOCATED_CPU} // 2;

    # add the params to the config file
    $config_vars{params} = $params;
    # write a config for the wrapper to parse
    write_file("$top/config.json", JSON::XS->new->pretty->canonical->encode(\%config_vars));
    # pushing the wrapper command
    print STDERR "Starting the python wrapper....\n";
    
    my @cmd = ("python3", "$wf_dir/snakefile/wrapper.py", "$top/config.json");

    print STDERR "Run: @cmd\n";
    my $ok = IPC::Run::run(\@cmd);
    if (!$ok)
    {
     die "wrapper command failed $?: @cmd";
    }
    # check if Job Failed txt file exisits
    my $filename = "JobFailed.txt";
    job_failed_exists($filename, $app, $output);
    save_output_files($app, $output);
}

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params);

    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);

    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }

    # using the memory requirement for the sars-onecodex assembly
    my $mem = '16G';
    
    my $time = 60 * 60 * 10;
    my $pf = {
	cpu => 6,
	memory => $mem,
	runtime => $time,
	storage => 1.1 * ($comp_size + $uncomp_size),
    };
    return $pf;
}

sub save_output_files
{
    my($app, $output) = @_;
    my %suffix_map = (
        bai => 'bai',
        bam => 'bam',
        csv => 'csv',
        depths => 'txt',
        err => 'txt',
        fasta => "contigs",
        html => 'html',
        out => 'txt',
        png => 'png',
        tsv => 'tsv',
        txt => 'txt',);

    my @suffix_map = map { ("--map-suffix", "$_=$suffix_map{$_}") } keys %suffix_map;

    if (opendir(D, $output))
    {
	while (my $p = readdir(D))
	{
	    next if ($p =~ /^\./);
	    my @cmd = ("p3-cp", "--recursive", @suffix_map, "$output/$p", "ws:" . $app->result_folder);
	    print STDERR "saving files to workspace... @cmd\n";
	    my $ok = IPC::Run::run(\@cmd);
	    if (!$ok)
	    {
		warn "Error $? copying output with @cmd\n";
	    }
	}
    closedir(D);
    }
}