package npg_pipeline::product::release;

use namespace::autoclean;

use Data::Dump qw{pp};
use Moose::Role;
use List::Util qw{all any};
use Readonly;

with qw{WTSI::DNAP::Utilities::Loggable
        npg_tracking::util::pipeline_config};

our $VERSION = '0';

Readonly::Scalar our $S3_RELEASE                      => q{s3};
Readonly::Scalar our $IRODS_RELEASE                   => q{irods};
Readonly::Scalar our $IRODS_PP_RELEASE                => q{irods_pp};

Readonly::Scalar my $QC_OUTCOME_MATTERS_KEY           => q{qc_outcome_matters};
Readonly::Scalar my $ACCEPT_UNDEF_QC_OUTCOME_KEY      => q{accept_undef_qc_outcome};
Readonly::Scalar my $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY => q{s3};

=head1 SUBROUTINES/METHODS

=head2 expected_files

  Arg [1]    : Data product whose files to list, npg_pipeline::product.

  Example    : my @files = $obj->expected_files($product)
  Description: Return a sorted list of the files expected to be present for
               archiving in the runfolder.

  Returntype : Array

=cut

sub expected_files {
  my ($self, $product) = @_;

  $product or $self->logconfess('A product argument is required');

  my @expected_files;
  my $lims = $product->lims or
    $self->logcroak('Product requires lims attribute to determine alignment');
  my $aligned = $lims->study_alignments_in_bam;

  my $dir_path = $product->existing_path($self->archive_path());
  my @extensions = qw{cram cram.md5 seqchksum sha512primesums512.seqchksum};
  if ( $aligned ) { push @extensions, qw{cram.crai bcfstats}; }
  push @expected_files,
    map { $product->file_path($dir_path, ext => $_) } @extensions;

  my @suffixes = qw{F0x900 F0xB00};
  if  ( $aligned ) { push @suffixes, qw{F0xF04_target F0xF04_target_autosome}; }
  push @expected_files,
    map { $product->file_path($dir_path, suffix => $_, ext => 'stats') }
    @suffixes;

  if ($aligned){
    my $qc_path = $product->existing_qc_out_path($self->archive_path());
    my @qc_extensions = qw{verify_bam_id.json};
    push @expected_files,
      map { $product->file_path($qc_path, ext => $_) } @qc_extensions;
  }

  @expected_files = sort @expected_files;

  return @expected_files;
}

=head2 is_release_data

  Arg [1]    : npg_pipeline::product

  Example    : $obj->is_release_data($product)
  Description: Return true if the product is data for release i.e.
                - is not spiked-in control data
                - is not data from tag zero, ie leftover data
                  after deplexing

  Returntype : Bool

=cut

sub is_release_data {
  my ($self, $product) = @_;

  $product or $self->logconfess('A product argument is required');

  my $rpt = $product->rpt_list();
  my $name = $product->file_name_root();
  if ($product->is_tag_zero_product) {
    $self->debug("Product $name, $rpt is NOT for release (is tag zero)");
    return 0;
  }

  if ($product->lims->is_control) {
    $self->debug("Product $name, $rpt is NOT for release (is control)");
    return 0;
  }

  $self->debug("Product $name, $rpt is for release ",
              '(is not tag zero or control)');

  return 1;
}

=head2 has_qc_for_release

  Arg [1]    : npg_pipeline::product

  Example    : $obj->has_qc_for_release($product)
  Description: Return true if the product has passed all QC necessary
               to be released.

  Returntype : Bool

=cut

sub has_qc_for_release {
  my ($self, $product) = @_;

  $product or $self->logconfess('A product argument is required');

  my $qc_db_accessor = 'qc_schema';
  $self->can($qc_db_accessor) or $self->logcroak(
    "$qc_db_accessor attribute should be implemented");
  $self->$qc_db_accessor or $self->logcroak(
    "$qc_db_accessor connection should be defined");

  my $rpt  = $product->rpt_list();
  my $name = $product->file_name_root();
  my $accept_undef_qc_outcome =
    $self->accept_undef_qc_outcome($product,$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY);

  my @seqqc =  $product->seqqc_objs($self->$qc_db_accessor);

  if (!@seqqc) {#if seqqc outcome is undef
    if ($accept_undef_qc_outcome) {
      return 1;
    } else {
      $self->logcroak('Seq QC is not defined');
    }
  }

  #if seqqc is not final
  if (any {not $_->has_final_outcome} @seqqc) {
    $self->logcroak("Product $name, $rpt are not all Final seq QC values");
  }

  #seqqc is FINAL from this point
  #returning early if any seqqc is FINAL REJECTED
  if (any {$_->is_rejected} @seqqc) {
    return 0;
  }

  #seqqc is FINAL ACCEPTED from this point
  my $libqc_obj = $product->libqc_obj($self->$qc_db_accessor);# getting regular lib values
  #checking if libqc is undef
  $libqc_obj or $self->logcroak('lib QC is undefined');

  if (not $libqc_obj->has_final_outcome ) {# if libqc is not final
    $self->logcroak("Product $name, $rpt is not Final lib QC value");
  }

  #libqc is final from this point
  #if it's neither rejected nor accepted it's undecided
  return $libqc_obj->is_accepted     ? 1
         : ($libqc_obj->is_rejected  ? 0
         : ($accept_undef_qc_outcome ? 1 : 0));
}

=head2  qc_outcome_matters

  Arg [1]    : npg_pipeline::product
  Arg [2]    : Str

  Example    : $obj->qc_outcome_matters($product, q[s3])
  Description: Returns a boolean value indicating whether or not QC outcome
               matters for the product to be archived by an archiver given
               by the second argument.

  Returntype : Bool

=cut

sub qc_outcome_matters {
  my ($self, $product, $archiver) = @_;
  $product  or $self->logconfess('A product argument is required');
  $archiver or $self->logconfess('An archiver argument is required');
  return $self->find_study_config($product)->{$archiver}->{$QC_OUTCOME_MATTERS_KEY};
}

=head2  accept_undef_qc_outcome

  Arg [1]    : npg_pipeline::product
  Arg [2]    : Str

  Example    : $obj->accept_undef_qc_outcome($product, q[s3])
  Description: Returns a boolean value indicating whether or not QC outcome
               can be undefined for the product to be archived by an archiver given
               by the second argument.

  Returntype : Bool

=cut

sub accept_undef_qc_outcome {
  my ($self, $product,$archiver) = @_;
  $product  or $self->logconfess('A product argument is required');
  $archiver or $self->logconfess('An archiver argument is required');
  return $self->find_study_config($product)->{$archiver}->{$ACCEPT_UNDEF_QC_OUTCOME_KEY};
}


=head2 customer_name

  Arg [1]    : npg_pipeline::product

  Example    : $obj->customer_name($product)
  Description: Return a name for the customer to whom data are being
               released.

  Returntype : Str

=cut

sub customer_name {
  my ($self, $product) = @_;

  my $customer_name = $self->find_study_config($product)
                      ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{customer_name};
  $customer_name or
    $self->logcroak(
      sprintf q{Missing %s archival customer name in configuration file for product %s},
      $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY, $product->composition->freeze());

  if (ref $customer_name) {
    $self->logconfess('Invalid customer name in configuration file: ',
                      pp($customer_name));
  }

  return $customer_name;
}

=head2 receipts_location

  Arg [1]    : npg_pipeline::product

  Example    : $obj->receipts_location($product);
  Description: Return location of the receipts for S3 submission,
               the value might be undefined.

  Returntype : Str

=cut

sub receipts_location {
  my ($self, $product) = @_;
  return $self->find_study_config($product)
           ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{receipts};
}

=head2 is_for_release

  Arg [1]    : npg_pipeline::product or st::api::lims or similar
  Arg [2]    : Str, type of release

  Example    : $obj->is_for_release($product, 'irods');
               $obj->is_for_release($product, 's3');
  Description: Return true if the product is to be released via the
               mechanism defined by the second argument.

  Returntype : Bool

=cut

sub is_for_release {
  my ($self, $product, $type_of_release) = @_;

  my @rtypes = ($IRODS_RELEASE, $IRODS_PP_RELEASE, $S3_RELEASE);

  $type_of_release or
      $self->logcroak(q[A defined type_of_release argument is required, ],
                      q[expected one of: ], pp(\@rtypes));

  any { $type_of_release eq $_ } @rtypes or
      $self->logcroak("Unknown release type '$type_of_release', ",
                      q[expected one of: ], pp(\@rtypes));

  my $study_config = (ref $product eq 'npg_pipeline::product')
                   ? $self->find_study_config($product)
                   : $self->study_config($product); # the last one is for lims objects
  return $study_config->{$type_of_release}->{enable};
}

=head2 is_for_s3_release

  Arg [1]    : npg_pipeline::product

  Example    : $obj->is_for_s3_release($product)
  Description: Return true if the product is configured for cloud archivel.
               Raise an error if no cloud URL has been configured.

  Returntype : Bool

=cut

sub is_for_s3_release {
  my ($self, $product) = @_;

  $product or $self->logconfess('A product argument is required');

  my $name        = $product->file_name_root();
  my $description = $product->composition->freeze();

  my $enable = $self->is_for_release($product, $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY);

  if ($enable and not $self->s3_url($product)) {
    $self->logconfess("Configuration error for product $name, $description: " ,
      "$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY release is enabled but no URL was provided");
  }

  $self->info(sprintf 'Product %s, %s is %sfor %s release',
    $name, $description, $enable ? q[] : q[NOT ], $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY);

  return $enable;
}

=head2 s3_url

  Arg [1]    : npg_pipeline::product

  Example    : $obj->s3_url($product)
  Description: Return a cloud URL for release of the product or undef
               if there is no URL.

  Returntype : Str

=cut

sub s3_url {
  my ($self, $product) = @_;

  my $url = $self->find_study_config($product)
                 ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{url};
  if (ref $url) {
    $self->logconfess(sprintf 'Invalid %s URL in configuration file: %',
                      $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY, pp($url));
  }

  return $url;
}

=head2 s3_profile

  Arg [1]    : npg_pipeline::product

  Example    : $obj->s3_profile($product)
  Description: Return a cloud profile name for release of the product or
               undef if there is no profile. A profile is a named set of
               credentials used by some cloud client software.

  Returntype : Str

=cut

sub s3_profile {
  my ($self, $product) = @_;

  my $profile = $self->find_study_config($product)
                     ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{profile};
  if (ref $profile) {
    $self->logconfess('Invalid %s profile in configuration file: ',
                      $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY, pp($profile));
  }

  return $profile;
}

=head2 s3_date_binning

  Arg [1]    : npg_pipeline::product

  Example    : $obj->s3_date_binning($product)
  Description: Return true if a date of processing element is to be added
               as the root of the object prefix the S3 bucket. e.g.

               ./2019-01-31/...

  Returntype : Bool

=cut

sub s3_date_binning {
  my ($self, $product) = @_;

  return $self->find_study_config($product)
              ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{date_binning};
}

=head2 is_s3_releasable

  Arg [1]    : npg_pipeline::product

  Example    : $obj->is_for_s3_release($product)
  Description: Return true if the product is to be archived to a cloud
               destination. If the QC outcome matters for being releasable,
               the product's QC outcome should be compatible with being
               released.

  Returntype : Bool

=cut

sub is_s3_releasable {
  my ($self, $product) = @_;

  return $self->is_release_data($product)   &&
         $self->is_for_s3_release($product) &&
         ( !$self->qc_outcome_matters($product, $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY) ||
           $self->has_qc_for_release($product) );
}

=head2 is_for_s3_release_notification

  Arg [1]    : npg_pipeline::product

  Example    : $obj->is_for_s3_release_notification($product)
  Description: Return true if a notification is to be sent on the
               external archival of the product.

  Returntype : Bool

=cut

sub is_for_s3_release_notification {
  my ($self, $product) = @_;

  my $rpt          = $product->rpt_list();
  my $name         = $product->file_name_root();
  my $m = "for $CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY release notification";

  if ($self->find_study_config($product)
           ->{$CLOUD_ARCHIVE_PRODUCT_CONFIG_KEY}->{notify}) {
    $self->info("Product $name, $rpt is $m");
    return 1;
  }

  $self->info("Product $name, $rpt is NOT $m");

  return 0;
}

=head2 haplotype_caller_enable
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->haplotype_caller_enable($product)
 Description: Return true if HaplotypeCaller is to be run on the product.
 
 Returntype : Bool
 
=cut

sub haplotype_caller_enable {
  my ($self, $product) = @_;

  my $rpt          = $product->rpt_list();
  my $name         = $product->file_name_root();

  if ($self->find_tertiary_config($product)->{haplotype_caller}->{enable}) {
    $self->info("Product $name, $rpt is for HaplotypeCaller processing");
    return 1;
  }

  $self->info("Product $name, $rpt is NOT for HaplotypeCaller processing");

  return 0;
}

=head2 haplotype_caller_chunking
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->haplotype_caller_chunking($product)
 Description: Returns base name of chunking file for product.

 Returntype : Str
 
=cut

sub haplotype_caller_chunking {
  my ($self, $product) = @_;

  return $self->find_tertiary_config($product)->{haplotype_caller}->{sample_chunking};
}

=head2 haplotype_caller_chunking_number
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->haplotype_caller_chunking_number($product)
 Description: Returns number of chunks for product.
 
 Returntype : Str
 
=cut

sub haplotype_caller_chunking_number {
  my ($self, $product) = @_;

  return $self->find_tertiary_config($product)->{haplotype_caller}->{sample_chunking_number};
}



=head2 bqsr_enable
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->bqsr_enable($product)
 Description: Return true if BQSR is to be run on the product.
 
 Returntype : Bool
 
=cut

sub bqsr_enable {
  my ($self, $product) = @_;

  my $rpt          = $product->rpt_list();
  my $name         = $product->file_name_root();

  if ($self->find_tertiary_config($product)->{bqsr}->{enable}) {
    $self->info("Product $name, $rpt is for BQSR processing");
    return 1;
  }

  $self->info("Product $name, $rpt is NOT for BQSR processing");

  return 0;
}


=head2 bqsr_apply_enable
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->bqsr_enable($product)
 Description: Return true if BQSR is to be applied to the product.
 
 Returntype : Bool
 
=cut

sub bqsr_apply_enable {
  my ($self, $product) = @_;

  my $rpt          = $product->rpt_list();
  my $name         = $product->file_name_root();

  if ($self->find_tertiary_config($product)->{bqsr}->{apply}) {
    $self->info("Product $name, $rpt is for BQSR application");
    return 1;
  }

  $self->info("Product $name, $rpt is NOT for BQSR application");

  return 0;
}


=head2 bqsr_known_sites
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->bqsr_known_sites($product)
 Description: Returns array of known sites for product.
 
 Returntype : Array[Str]
 
=cut

sub bqsr_known_sites {
  my ($self, $product) = @_;
  my @known_sites = @{$self->find_tertiary_config($product)->{bqsr}->{'known-sites'}};
  return @known_sites;
}

=head2 bwakit_enable
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->bwakit_enable($product)
 Description: Return true if bwakit's postalt processing is to be run on the product.
 
 Returntype : Bool
 
=cut

sub bwakit_enable {
  my ($self, $product) = @_;

  my $rpt          = $product->rpt_list();
  my $name         = $product->file_name_root();

  if ($self->find_study_config($product)->{bwakit}->{enable}) {
    $self->info("Product $name, $rpt is for bwakit postalt processing");
    return 1;
  }

  $self->info("Product $name, $rpt is NOT for bwakit postalt processing");

  return 0;
}

=head2 markdup_method

  Arg [1]    : npg_pipeline::product

  Example    : $obj->markdup_method($product);
  Description: Return mark duplicate method,
               the value might be undefined.

  Returntype : Str

=cut

sub markdup_method {
  my ($self, $product) = @_;
  return $self->find_study_config($product)->{markdup_method};
}

=head2 staging_deletion_delay
 
 Arg [1]    : npg_pipeline::product
 
 Example    : $obj->staging_deletion_delay($product)
 Description: If the study has staging deletion delay configured,
              returns this value, otherwise returns an undefined value.
 
 Returntype : Int
 
=cut

sub staging_deletion_delay {
  my ($self, $product) = @_;
  return $self->find_study_config($product)->{'data_deletion'}->{'staging_deletion_delay'};
}

1;

__END__

=head1 NAME

npg_pipeline::product::release

=head1 SYNOPSIS

  foreach my $product (@products) {
    if ($self->is_release_data($product)    and
        $self->has_qc_for_release($product)) {
      $self->do_release($product);
    }
  }

=head1 DESCRIPTION

A role providing configuration and methods for decision-making during
product release.

The configuration file gives per-study settings and a default to be
used for any study without a specific configuration.

 S3:
    enable: <boolean> S3 release enabled if true.
    url:    <URL>     The S3 bucket URL to send to.
    notify: <boolean> A notificastion message will be sent if true.

 irods:
    enable: <boolean> iRODS release enabled if true.
    notify: <boolean> A notification message will be sent if true.

e.g.

---
default:
  s3:
    enable: false
    url: null
    notify: false
  irods:
    enable: true
    notify: false

study:
  - study_id: "5290"
    s3:
      enable: true
      url: "s3://product_bucket"
      notify: true
    irods:
      enable: false
      notify: false

  - study_id: "1000"
    s3:
      enable: false
      url: null
      notify: false
    irods:
      enable: true
      notify: false

=head1 BUGS AND LIMITATIONS

=head1 INCOMPATIBILITIES

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Data::Dump

=item Moose::Role

=item Readonly

=item WTSI::DNAP::Utilities::Loggable

=item npg_tracking::util::pipeline_config

=back

=head1 AUTHOR

=over

=item Keith James

=item Fred Dodd

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018,2019,2020,2021 Genome Research Ltd.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
