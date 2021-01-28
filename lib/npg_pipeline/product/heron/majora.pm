#!/usr/bin/env perl
package npg_pipeline::product::heron::majora;
use autodie;
use strict;
use warnings;
use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;
use Carp;
use JSON;
use English qw( -no_match_vars );
use DateTime;
use Readonly;
use Exporter qw(import);
use HTTP::Request;
use JSON::MaybeXS qw(encode_json);
use LWP::UserAgent;
use Log::Log4perl qw(:easy);
use npg_tracking::Schema;
use WTSI::DNAP::Warehouse::Schema;

with qw{MooseX::Getopt};

our $VERSION = '0';

our @EXPORT_OK = qw/  get_table_info_for_id_run
                      get_majora_data
                      json_to_structure
                      update_metadata
                      get_id_runs_missing_data
                      get_id_runs_missing_data_in_last_days
                      update_majora/;

has '_npg_tracking_schema'    => (
    isa        => q{DBIx::Class::Schema},
    is         => q{ro},
    builder    => q{_build__npg_tracking_schema},
    required   => 1,
    lazy_build => 1,
);

has '_mlwh_schema'    => (
    isa        => q{DBIx::Class::Schema},
    is         => q{ro},
    builder    => q{_build__mlwh_schema},
    required   => 1,
    lazy_build => 1,
);

has 'verbose'  => (
    isa     => q{Bool},
    is      => q{ro},
    default => 1,
    lazy    => 1,
);

has 'dry_run'  => (
    isa     => q{Bool},
    is      => q{ro},
    default => 0,
    lazy    => 1,
);

has 'days' => (
    isa    => q(Int),
    is     => q(ro),
);

has 'update'  => (
    isa     => q{Bool},
    is      => q{ro},
    default => q{0},
    lazy    => 1,
);

has 'id_runs' => (
    isa     => q{ArrayRef[Int]},
    is      => q{rw},
    default => sub {[]},
);

has 'logger' => (
    isa        => q{Log::Log4perl::Logger},
    is         => q{rw},
    builder    => q{_build_logger},
    lazy_build => 1,
);


sub _build__npg_tracking_schema {
  return npg_tracking::Schema->connect();
}

sub _build__mlwh_schema {
  return WTSI::DNAP::Warehouse::Schema->connect();
}

sub _build_logger {
  my $self=shift;
  Log::Log4perl->easy_init({layout => '%d %-5p %c - %m%n'});
  my $logger = Log::Log4perl->get_logger();
  $logger->level($self->verbose ? $DEBUG : $INFO);
  return $logger;
}

sub run {
  my $self = shift;
  my %majora_update_runs= $self->update? (map{$_ => 1} @{$self->id_runs}) : ();
 
  if (($self->update) and ($self->dry_run)){
    $self->logger->error_die('both --update and --dry_run are set');
  }
  if (($self->days) and ($self->days eq '0')){
    $self->logger->error_die('cannot set days to 0');
  }

  if ((not @{$self->id_runs}) and (not $self->days)) {
    #gets a list of id_runs missing data
    $self->logger->info('Getting id_runs missing COG metadata');
 
    my @id_runs_missing_data = $self->get_id_runs_missing_data();
    $self->id_runs(\@id_runs_missing_data); 
 
    if ($self->update) {
      $self->logger->debug('Getting id_runs with missing data for Majora update');
      %majora_update_runs=(map{$_ => 1} $self->get_id_runs_missing_data( [undef]) );
    }

  }elsif((not @{$self->id_runs}) and $self->days) {
    #gets list of id_runs missing data from (current time - days) up to current time
    my @id_runs_missing_data = $self->get_id_runs_missing_data_in_last_days();
    $self->id_runs(\@id_runs_missing_data);
    $self->logger->debug( join(', ' ,@{$self->id_runs}).' = id_runs after getting missing data from the last '. $self->days . ' days');

    if ($self->update) {
      $self->logger->debug('Selecting id_runs missing data from the last '. $self->days.' days for Majora update');
      %majora_update_runs=(map{$_ => 1}$self->get_id_runs_missing_data_in_last_days([undef]));
    }

  }elsif((@{$self->id_runs}!= 0) and ($self->days or ($self->days eq '0'))){
    $self->logger->error_die('Cannot set both id_runs and days');
  };

  for my $id_run (@{$self->id_runs}){
    if (($majora_update_runs{$id_run}) and (not $self->dry_run)){
      $self->logger->info("Updating Majora for $id_run");
      $self->update_majora($id_run);
    }
    $self->logger->info("Fetching npg_tracking and Warehouse DB info for $id_run");
    my ($fn,$rs) = $self->get_table_info_for_id_run($id_run);
 
    $self->logger->info("Fetching Majora data for $fn");
    my $json_string = $self->get_majora_data($fn);      
    
    $self->logger->debug('Converting the json returned from Majora to perl structure');
    my %ds = $self->json_to_structure($json_string,$fn);
    my $ds_ref = \%ds;
    
    if (not $self->dry_run){
      $self->logger->info("Updating Metadata for $id_run");
      $self->update_metadata($rs,$ds_ref);
    }
  }
}

sub get_table_info_for_id_run {
  my $self = shift;
  my ($id_run)= @_ ;
  if (!defined $id_run) {$self->logger->error_die('need an id_run');};

  my$rs=$self->_npg_tracking_schema->resultset(q(Run));
  my$fn=$rs->find($id_run)->folder_name;

  my $rs_iseq=$self->_mlwh_schema->resultset('IseqProductMetric')->search({'id_run' => $id_run},
                                     {join=>{'iseq_flowcell' => 'sample'}});
  my @table_info = ($fn,$rs_iseq);
  return (@table_info);
}

sub get_majora_data {
  my $self = shift;
  my ($fn) = @_;
  my $url =q(/api/v2/process/sequencing/get/);
  my $data_to_encode = {run_name=>["$fn"]};
  my $res = $self->_use_majora_api('POST',$url,$data_to_encode);
  return($res);
}

sub json_to_structure {
  my $self = shift;
  my ($json_string, $fn) = @_;
  my $data = from_json($json_string);
  if (@{$data->{ignored}} != 0) {
    $self->logger->error("response from Majora ignored a folder : " . $json_string);
  }
  my %data_structure= ();
  if ($data) {
    my $libref = $data->{get}{$fn}{libraries}|| [];
    my @libarray = @{$libref};
    foreach my $lib (@libarray) {
      my $lib_name = $lib->{library_name};
      my $bioref = $lib->{biosamples};
      my @biosamples = @{$bioref};
      foreach my $sample (@biosamples) {
        my $central_sample_id=$sample->{central_sample_id};
        $data_structure{$lib_name}->{$central_sample_id}=$sample;
      }
    }
  }
  return(%data_structure);
}

sub update_metadata {
  my $self = shift;
  my ($rs_iseq,$ds_ref) = @_; 
  my %data_structure = %{$ds_ref};
  while (my $row=$rs_iseq->next) {
    my $fc = $row->iseq_flowcell;
    $fc or next;
    my $libdata = $data_structure{$fc->id_pool_lims};
    my $sample_data;
    my $sample_meta;
    if ($libdata) {
      my $sname = $fc->sample->supplier_name;
      next unless $sname;
      $sample_data = $libdata->{$fc->sample->supplier_name}; 
      if ($sample_data) {
        $sample_meta = defined $sample_data->{submission_org} ?1:0;
        $self->logger->info("setting $sample_meta for ". $fc->sample->supplier_name);
      }
    }
    $row->iseq_heron_product_metric->update({cog_sample_meta=>$sample_meta});
  };
  return;
}

sub _get_id_runs_missing_cog_metadata_rs{
  my $self = shift;
  my ($meta_search) = @_;
  $meta_search //= [undef,0]; # missing run -> library -> biosample connection, or missing biosample metadata
  return $self->_mlwh_schema->resultset('IseqHeronProductMetric')->search(
    {
      'study.name'         => 'Heron Project',
      'me.cog_sample_meta' => $meta_search,
      'me.climb_upload'    => {-not=>undef} # only consider for data uploaded
    },
    {
      join => {'iseq_product_metric' => {'iseq_flowcell' => ['study']}},
      columns => 'iseq_product_metric.id_run',
      distinct => 1
    }
  );
}

sub get_id_runs_missing_data{
  my $self = shift;
  my ($meta_search) = @_;
  my @ids = map { $_->iseq_product_metric->id_run } $self->_get_id_runs_missing_cog_metadata_rs($meta_search)->all();
  return @ids;
}

sub get_id_runs_missing_data_in_last_days{
  my $self = shift;
  my ( $meta_search) = @_;
  my $dt = DateTime->now();
  $dt->subtract(days => $self->days);
  my $rs = $self->_get_id_runs_missing_cog_metadata_rs($meta_search)->search(
    {
      'me.climb_upload'    =>{ q(>) =>$dt }
    }
  );
  my @ids = map { $_->iseq_product_metric->id_run } $rs->all();
  return @ids;
}

sub update_majora{
  my $self = shift;
  my ($id_run)= @_ ;
  if (!defined $id_run) {carp 'need an id_run'};
  my$rn=$self->_npg_tracking_schema->resultset(q(Run))->find($id_run)->folder_name;
  my$rs=$self->_mlwh_schema->resultset(q(IseqProductMetric))->search_rs({'me.id_run'=>$id_run, tag_index=>{q(>) => 0}},{join=>{iseq_flowcell=>q(sample)}});
  my$rsu=$self->_mlwh_schema->resultset(q(Sample))->search({q(iseq_heron_product_metric.climb_upload)=>{q(-not)=>undef}},{join=>{iseq_flowcells=>{iseq_product_metrics=>q(iseq_heron_product_metric)}}});
  my%l2bs;my%l2pp;my%l2lsp; my%r2l;
  while (my$r=$rs->next){
      my$ifc=$r->iseq_flowcell ;# or next;
      my$bs=$ifc->sample->supplier_name;
      my$lb=$ifc->id_pool_lims;
      # lookup by library and sample name - skip if no climb_uploads.
      if(not $rsu->search({q(me.supplier_name)=>$bs, q(iseq_flowcells.id_pool_lims)=>$lb})->count() ) {next;}
      # i.e. do not use exising $r record as same library might upload differnt samples in differnt runs - Majora library must contain both
      my$pp=$r->iseq_flowcell->primer_panel;
      $pp=$pp=~m{nCoV-2019/V(\d)\b}smx?$1:q("");
      my$lt=$r->iseq_flowcell->pipeline_id_lims;
      my$lsp=q();
      if($lt=~m{^Sanger_artic_v[34]}smx or $lt=~m{PCR[ ]amplicon[ ]ligated[ ]adapters}smx){
         $lsp=q(LIGATION)
      }
      elsif($lt=~m{PCR[ ]amplicon[ ]tailed[ ]adapters}smx or $lt=~m{Sanger_tailed_artic_v1_384}smx){
        $lsp=q(TAILING)
      }
      else{
        $self->logger->error_die("Do not know how to deal with library type: $lt");
      }
      $r2l{$rn}{$lb}++;
      $l2bs{$lb}{$bs}++;
      $l2pp{$lb}{$pp}++;
      $l2lsp{$lb}{$lsp}++;
  }
  foreach my$lb(sort keys %l2bs){
    $self->logger->error_die("multiple primer panels in $lb") if (1!=keys %{$l2pp{$lb}});
    $self->logger->error_die("multiple library seq protocol in $lb") if (1!=keys %{$l2lsp{$lb}});
    my($pp)=keys %{$l2pp{$lb}};
    my($lsp)=keys %{$l2lsp{$lb}};

    my $url = q(api/v2/artifact/library/add/);
    my @biosample_info;
    foreach my $key (keys%{$l2bs{$lb}}){
      push @biosample_info, {central_sample_id=>$key,
                             library_selection=>'PCR',
                             library_source   =>'VIRAL_RNA',
                             library_strategy =>'AMPLICON',
                             library_protocol =>q{},
                             library_primers  =>$pp
                            };
    }
    my $data_to_encode = {
                                  library_name=>$lb,
                                  library_layout_config=>'PAIRED',
                                  library_seq_kit=> 'NEB ULTRA II',
                                  library_seq_protocol=> $lsp,
                                  force_biosamples=> \1, # JSON encode as true, Sanger-only Majora interaction
                                  biosamples=>[@biosample_info]
                       };
   $self->logger->debug("Sending call to update Majora for library $lb");
   $self->_use_majora_api('POST', $url, $data_to_encode);
  }
  # adding sequencing run
  foreach my$rn(sort keys%r2l){
    foreach my$lb(sort keys %{$r2l{$rn}}){

      my $url = q(api/v2/process/sequencing/add/);
      #TODO to get instrument type properly - use ISeqRunLaneMetric
      my $instrument_model= ($rn=~m{_MS}smx?q(MiSeq):q(NovaSeq));
      my $data_to_encode = {
                            library_name=>$lb,
                            runs=> [{
                                     run_name=>$rn,
                                     instrument_make=>'ILLUMINA',
                                     instrument_model=>$instrument_model
                                   }]
                           };
      $self->logger->debug("Sending call to update Majora for library $lb");
      $self->_use_majora_api('POST', $url, $data_to_encode);
    }
  }
 return;
}

sub _use_majora_api{
  my $self = shift;
  my ($method,$url_end,$data_to_encode) = @_;
  $data_to_encode = {%{$data_to_encode}};
  my $url = $ENV{MAJORA_DOMAIN}.$url_end;
  my $header;
  if (my $token = $ENV{MAJORA_OAUTH_TOKEN}){
    $header = [q(Authorization) => qq(Bearer $token) ,q(Content-Type) => q(application/json; charset=UTF-8)];
    $data_to_encode->{token} = 'DUMMYTOKENSTRING';
  }else{
    $header = [q(Content-Type) => q(application/json; charset=UTF-8)];
    $data_to_encode->{token} = $ENV{MAJORA_TOKEN};
  }
  $data_to_encode->{username} = $ENV{MAJORA_USER};
  my $encoded_data = encode_json($data_to_encode);
  my $ua = LWP::UserAgent->new();
  my $r = HTTP::Request->new($method, $url, $header, $encoded_data);
  my$res= $ua->request($r);
  if ($res->is_error){
    $self->logger->error_die(q(Majora API returned a ).($res->code).qq( code. Content:\n).($res->decoded_content()).qq(\n));
  }
  return $res->decoded_content;
}

__PACKAGE__->meta->make_immutable;

1;
__END__

=head1 NAME

npg_heron::majora

=head1 SYNOPSIS

Perl script used to update Majora data and/or id_run cog_sample_meta data.

=head1 SUBROUTINES/METHODS

=head2 run

Takes the options (--dry_run, --verbose,--id_run,--update,--days)
from command line using Moose::GetOpt,to run the methods based on 
the options given.

=head2 get_table_info_for_id_run

Takes an id_run as argument.
Returns an List containing the id_run, corresponding foldername and
the resultset from IseqProductMetrics table in the database for the
given id_run.
 
=head2 get_majora_data

Takes the folder name (corresponding to the given id_run) as an 
argument.
Returns JSON data fetched from Majora as a string value.

=head2 json_to_structure

Takes two arguments.
First argument - the JSON output returned from get_majora_data
stored as a string.
Second argument - the foldername relating to the id_run.
Converts the JSON format to a perl data structure of the format:
Library name => Biosample name => central sample id => sample data
Returns hash reference to the data structure created.
 
=head2 update_metadata

Takes two arguments.
First argument - The result set of the ISeqProductMetrics table.
Second argument - hash reference to the datastructure returned by the
method json_to_structure.
Updates the mlwarehouse database with the new cog_sample_meta values
depending on the whether there is sample data for the given run in Majora.
If there IS NO sample data:
cog_sample_meta is set to NULL.
If there IS sample data AND there IS a value for submission_org:
cog_sample_meta is set to 1.
If there IS sample data AND there IS NO value for submission_org:
cog_sample_meta is set to 0.

=head2 get_id_runs_missing_data

Optionally takes an argument: array ref of cog_sample_meta to search 
for (default [undef,0]).
searches schema for Heron runs which are missing cog_sample_meta
values and returns as a list their id_runs.

=head2 get_id_runs_missing_data_in_last_days

Optionally takes an argument: array ref of cog_sample_meta to search 
for (default [undef,0]).
id_runs will be fetched.

=head2 update_majora

Takes id_run as argument, to then call api to update Majora.

=head1 DIAGNOSTICS
=head1 CONFIGURATION AND ENVIRONMENT
=head1 DEPENDENCIES
=head1 USAGE

npg_majora_for_mlwh [--verbose][--dry_run][--update][--id_run <id_run>][--days <days>]

=head1 REQUIRED ARGUMENTS
=head1 OPTIONS
=head1 EXIT STATUS
=head1 CONFIGURATION
=over
=item JSON
=back
=head1 INCOMPATIBILITIES
=head1 BUGS AND LIMITATIONS
=head1 AUTHOR
Fred Dodd
=head1 LICENSE AND COPYRIGHT
Copyright (C) 2020 GRL
This file is part of NPG.
NPG is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
=cut