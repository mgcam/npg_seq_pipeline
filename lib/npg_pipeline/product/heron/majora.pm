#!/usr/bin/env perl
package npg_pipeline::product::heron::majora;
use autodie;
use strict;
use warnings;
use Carp;
use JSON;
use English qw( -no_match_vars );
use DateTime;
use Exporter qw(import);

our $VERSION = '0';

our @EXPORT_OK = qw/  get_table_info_for_id_run
                      get_majora_data
                      json_to_structure
                      update_metadata
                      get_ids_missing_data
                      get_ids_from_date/;

sub get_table_info_for_id_run {
  my ($id_run,$npg_tracking_schema,$mlwh_schema)= @_ ;
  if (!defined $id_run) {carp 'need an id_run'};

  my$rs=$npg_tracking_schema->resultset(q(Run));
  my$fn=$rs->find($id_run)->folder_name;

  my $rs_iseq=$mlwh_schema->resultset('IseqProductMetric')->search({'id_run' => $id_run},
                                     {join=>{'iseq_flowcell' => 'sample'}});
  my @table_info = ($fn,$rs_iseq);
  return (@table_info);
}

sub get_majora_data {
  my ($fn) = @_;
  my @curl_command = qw(curl -s -L);
  if (my $token = $ENV{MAJORA_OAUTH_TOKEN}){
    push @curl_command,('--header',"Authorization: Bearer $token");
  }
  push @curl_command,('--header', 'Content-Type: application/json', '--request', 'POST', '--data', qq({"username":"$ENV{MAJORA_USER}", "token":"$ENV{MAJORA_TOKEN}", "run_name":["$fn"]}), "$ENV{MAJORA_DOMAIN}/api/v2/process/sequencing/get/");
  open my $fh, q[-|], @curl_command;
  my $curldata;
  do {
    local $INPUT_RECORD_SEPARATOR = undef;
    $curldata = <$fh>;
  };
  close $fh;
  $curldata or carp 'nothing back from curl';
  return($curldata);
}

sub json_to_structure {
  my ($json_string, $fn) = @_;
  my $data = from_json($json_string);
  my %data_structure= ();
  if ($data) {
    my $libref = $data->{get}{$fn}{libraries};
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
  my ($rs_iseq,$ds_ref) = @_;
  my %data_structure = %{$ds_ref};
  while (my $row=$rs_iseq->next) {
    my $fc = $row->iseq_flowcell;
    $fc or next;
    my $libdata = $data_structure{$fc->id_pool_lims};
    my $sample_data;
    my $sample_meta;
    if ($libdata) {
      $sample_data = $libdata->{$fc->sample->supplier_name};
      if ($sample_data) {
        $sample_meta = defined $sample_data->{submission_org} ?1:0;
        carp "setting $sample_meta for ". $fc->sample->supplier_name;
      }
    }
    $row->iseq_heron_product_metric->update({cog_sample_meta=>$sample_meta});
  };
  return;
}

sub _get_id_runs_missing_cog_metadata_rs{
  my ($schema) = @_;
  return $schema->resultset('IseqHeronProductMetric')->search(
    {
      'study.name'         => 'Heron Project',
      'me.cog_sample_meta' => [undef,0], # missing run -> library -> biosample connection, or missing biosample metadata
      'me.climb_upload'    => {-not=>undef} # only consider for data uploaded
    },
    {
      join => {'iseq_product_metric' => {'iseq_flowcell' => ['study']}},
      columns => 'iseq_product_metric.id_run',
      distinct => 1
    }
  );
}

sub get_ids_missing_data{
  my ($schema) = @_;
  my @ids = map { $_->iseq_product_metric->id_run } _get_id_runs_missing_cog_metadata_rs($schema)->all();
  return @ids;
}

sub get_ids_from_date{
  my ($schema, $days) = @_;
  my $dt_end = DateTime->now();
  my $dt_start = $dt_end->subtract(days =>$days);
  my $dtf = $schema->storage->datetime_parser;
  my $rs = _get_id_runs_missing_cog_metadata_rs($schema)->search(
    {
      #TODO: dates might not be matching climb_upload value exactly therefore not returning runs
      'me.climb_upload'    =>{ -between =>[$dtf->format_datetime($dt_start),
                                           $dtf->format_datetime($dt_end),
                                          ],
                             }
    }
  );
  my @ids = map { $_->iseq_product_metric->id_run } $rs->all();
  return @ids;
}
1;
__END__

=head1 NAME

npg_heron::majora

=head1 SYNOPSIS

#first setting schemas and id_run
my $id_run = <id_run>;
my $schema =npg_tracking::Schema->connect();
my $mlwh_schema=WTSI::DNAP::Warehouse::Schema->connect();

#Then the id_run, npg_tacking schema and mlwh schema are passed to 
#get_table_info_for_id_run. The folder name and IseqProductMetrics
#result set are returned
my ($fn,$rs) = get_table_info_for_id_run($id_run,$schema,$mlwh_schema);

#get_majora_data can be passed the foldername obtained by 
#get_table_info_for_id_run, which will return the a string containing
#the JSON information from majora.
my $json_string = get_majora_data($fn);

#We can then pass json_string with the folder name obtained before
#to json_to_structure which will return the data structure to parse
#This should then be turned into a reference to pass to update_metadata.

my %ds = json_to_structure($json_string,$fn);
my $ds_ref = \%ds;

#The result set of the npg_tracking schema and the data structure
#reference can then be passed to update_metadata to update the
# database.
update_metadata($rs,$ds_ref);

#Alternativley id runs with missing data can be obtained by running 
#get_ids_missing_data which takes a schema as argument and returns
#a list of id_runs
my @ids = get_ids_missing_data($schema);

#id_runs can also be obtained through get_ids_from_date which returns
#a list of id_runs from between the current time and X many days ago e.g
my @ids = get_ids_from_date($schema,4);
#gets ids between now and 4 days ago

=head1 DESCRIPTION

Module for updating cog_sample_meta in mlwarehouse database for a
particular id_run. 

=head1 SUBROUTINES/METHODS

=head2 get_table_info_for_id_run

Takes three arguments
First argument - An id_run.
Second argument - schema to get the folder name.
Third argument - mlwarehouse database schema.
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

=head2 get_ids_missing_data

Takes a schema as argument.
searches schema for Heron runs which are missing cog_sample_meta
values and returns as a list their id_runs.

=head2 get_ids_from_date

Takes two arguments.
First argument - Schema to get id_runs from.
Second argument - number of days before the current time from which
id_runs will be fetched.

=head1 DIAGNOSTICS
=head1 CONFIGURATION AND ENVIRONMENT
=head1 DEPENDENCIES
=head1 USAGE
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
