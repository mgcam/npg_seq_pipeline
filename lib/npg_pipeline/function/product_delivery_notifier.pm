package npg_pipeline::function::product_delivery_notifier;

use namespace::autoclean;

use Data::Dump qw{pp};
use English qw{-no_match_vars};
use File::Path qw{make_path};
use File::Spec::Functions;
use FindBin qw{$Bin};
use JSON;
use Moose;
use MooseX::StrictConstructor;
use Readonly;
use Try::Tiny;
use UUID qw{uuid};

use npg_pipeline::function::definition;
use npg_tracking::util::config_constants qw{$NPG_CONF_DIR_NAME};

extends 'npg_pipeline::base';

with qw{npg_pipeline::product::release};

Readonly::Scalar my $EVENT_TYPE            => 'npg.events.sample.completed';
Readonly::Scalar my $EVENT_ROLE_TYPE       => 'sample';
Readonly::Scalar my $EVENT_SUBJECT_TYPE    => 'data';
Readonly::Scalar my $EVENT_LIMS_ID         => 'npg';
Readonly::Scalar my $EVENT_USER_ID         => 'npg_pipeline';
Readonly::Scalar my $EVENT_MESSAGE_DIRNAME => 'messages';

Readonly::Scalar my $SEND_MESSAGE_SCRIPT   => 'npg_pipeline_notify_delivery';
Readonly::Scalar my $MESSAGE_CONFIG_FILE   => 'psd_production_events.conf';

Readonly::Scalar my $MD5SUM_LENGTH         => 32;


our $VERSION = '0';

## no critic (ValuesAndExpressions::RequireInterpolationOfMetachars)
has 'message_config' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   builder       => '_build_message_config',
   lazy          => 1,
   documentation => 'The path of the configuration file for the messaging ' .
                    'script. The default location for this file is in ' .
                    '$HOME/.npg/ and the default filename is ' .
                    'psd_production_events.conf',);
## use critic

has 'message_dir' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   builder       => '_build_message_dir',
   lazy          => 1,
   documentation => 'The directory where message JSON files will be saved',);


=head2 make_message

  Arg [1]    : Data product which the message will describe,
               npg_pipeline::product.

  Example    : my $msg = $obj->make_message($product)
  Description: Create a product delivery message as a Perl data structure.
               Encoding the returned value as JSON will yield a string
               suitable to be send as a message body.
  Returntype : HashRef

=cut

sub make_message {
  my ($self, $product) = @_;

  my $dir_path       = catdir($self->archive_path(), $product->dir_path());
  my $cram_file      = $product->file_path($dir_path, ext => 'cram');
  my $cram_md5_file  = $product->file_path($dir_path, ext => 'cram.md5');
  my $cram_md5       = $self->_read_md5_file($cram_md5_file);

  my $customer_name = $self->customer_name($product);
  $self->info("Using customer name '$customer_name'");

  my $flowcell_barcode = $product->lims->flowcell_barcode();
  my $sample_id        = $product->lims->sample_id();
  my $sample_name      = $product->lims->sample_name();
  my $supplier_name    = $product->lims->sample_supplier_name();
  $supplier_name or
    $self->logcroak(sprintf q{Missing supplier name for product %s, %s},
                    $product->file_name_root(), $product->rpt_list());

  my $message_uuid = uuid();
  my $subject_uuid = uuid(); # This is a placeholder until we can
                             # obtain the SScape UUID of the sample

  my $message_body =
    {
     'lims'  => $EVENT_LIMS_ID,
     'event' =>
     {'event_type'      => $EVENT_TYPE,
      'uuid'            => $message_uuid,
      'occurred_at'     => undef,
      'user_identifier' => $EVENT_USER_ID,
      'subjects'        =>[{
                            'role_type'     => $EVENT_ROLE_TYPE,
                            'subject_type'  => $EVENT_SUBJECT_TYPE,
                            'friendly_name' => $supplier_name,
                            'uuid'          => $subject_uuid,
                           }],
      'metadata' =>
      {
       'customer_name'        => $customer_name,
       'sample_id'            => $sample_id,
       'sample_name'          => $sample_name,
       'sample_supplier_name' => $supplier_name,
       # 'flowcell_barcode'     => $flowcell_barcode,
       'file_path'            => $cram_file,
       'file_md5'             => $cram_md5,
       'rpt_list'             => $product->rpt_list,
      }
     }
    };

  return $message_body;
}

=head2 create

  Arg [1]    : None

  Example    : my $defs = $obj->create
  Description: Create per-product function definitions.

  Returntype : ArrayRef[npg_pipeline::function::definition]

=cut

sub create {
  my ($self) = @_;

  if (! -d $self->message_dir) {
    make_path($self->message_dir);
  }

  my $id_run = $self->id_run();
  my @definitions;

  my $i = 0;
  foreach my $product (@{$self->products->{data_products}}) {
    next if not $self->is_release_data($product);
    next if not $self->has_qc_for_release($product);
    next if not $self->is_for_s3_release($product);
    next if not $self->is_for_s3_release_notification($product);

    my $msg_file = $product->file_path($self->message_dir, ext => 'msg.json');
    $self->_write_message_file($msg_file, $self->make_message($product));

    my $job_name = sprintf q{%s_%d_%d}, $SEND_MESSAGE_SCRIPT, $id_run, $i;
    my $command = sprintf q{%s --config %s %s},
      "$Bin/$SEND_MESSAGE_SCRIPT", $self->message_config(), $msg_file;

    push @definitions,
      npg_pipeline::function::definition->new
        ('created_by'  => __PACKAGE__,
         'created_on'  => $self->timestamp(),
         'identifier'  => $id_run,
         'job_name'    => $job_name,
         'command'     => $command,
         'composition' => $product->composition());
    $i++;
  }

  if (not @definitions) {
    push @definitions, npg_pipeline::function::definition->new
      ('created_by' => __PACKAGE__,
       'created_on' => $self->timestamp(),
       'identifier' => $id_run,
       'excluded'   => 1);
  }

  return \@definitions;
}

sub _build_message_config {
  my ($self) = @_;

  my $dir  = $ENV{'HOME'} || q{.};
  my $path = catdir($dir, $NPG_CONF_DIR_NAME);
  my $file = catfile($path, $MESSAGE_CONFIG_FILE);
  $self->info("Using messaging configuration file '$file'");

  return $file;
}

sub _build_message_dir {
  my ($self) = @_;

  return catdir($self->archive_path(), q[..], q[..], $EVENT_MESSAGE_DIRNAME);
}

sub _read_md5_file {
  my ($self, $md5_file) = @_;

  my $md5;
  open my $fh, '<', $md5_file or
    $self->logcroak("Failed to open '$md5_file' for reading: $ERRNO");
  $md5 = <$fh>;
  if ($md5) {
    chomp $md5;
  }
  close $fh or $self->logcroak("Failed to close '$md5_file': $ERRNO");

  if (not defined $md5 or length $md5 != $MD5SUM_LENGTH) {
    $self->logcroak("Corrupt MD5 '$md5' found in '$md5_file'");
  }

  return $md5;
}

sub _write_message_file {
  my ($self, $file_path, $message) = @_;

  $self->debug('Writing ', pp($message), " to '$file_path'");
  open my $fh, '>', $file_path or
    $self->logcroak("Failed to open '$file_path' for writing: $ERRNO");

  print {$fh} encode_json($message), "\n" or
    $self->logcroak("Failed to write to '$file_path': $ERRNO");

  close $fh or $self->logcroak("Failed to close '$file_path': $ERRNO");

  return;
}

__PACKAGE__->meta->make_immutable;

1;


__END__

=head1 NAME

npg_pipeline::function::product_delivery_notifier

=head1 SYNOPSIS

  my $obj = npg_pipeline::function::product_delivery_notifier
    (customer_name    => $customer,
     message_config   => '/path/to/config',
     runfolder_path   => $runfolder_path);

=head1 DESCRIPTION

Notifies a message queue that a set of data products from a sequencing
run have been delivered to a customer.

Notification is configured per-study using the configuration file
product_release.yml, see npg_pipeline::product::release.

The message_config file describes the host, port, user, password,
vhost, routing key and exchange for the message queue. E.g.

  host=localhost
  port=5672
  user=npg
  password=test
  vhost=/
  exchange=""

The password may be set through an environment variable. See the
npg_pipeline_notify_delivery script which is executed by this
notifier.

The default location of the file is $HOME/.npg/npg_message_queue.conf


=head1 SUBROUTINES/METHODS

=head1 BUGS AND LIMITATIONS

=head1 INCOMPATIBILITIES

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Data::Dump

=item JSON

=item Moose

=item Readonly

=item UUID

=back

=head1 AUTHOR

Keith James

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 Genome Research Ltd.

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