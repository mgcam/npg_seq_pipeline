use strict;
use warnings;

use Digest::MD5;
use File::Copy;
use File::Path qw[make_path];
use File::Temp;
use Log::Log4perl qw[:easy];
use Test::More tests => 4;
use Test::Exception;
use t::util;


Log::Log4perl->easy_init({level  => $INFO,
                          layout => '%d %p %m %n'});

{
  package TestDB;
  use Moose;

  with 'npg_testing::db';
}

# See README in fixtures for a description of the test data.
my $qc = TestDB->new
  (sqlite_utf8_enabled => 1,
   verbose             => 0)->create_test_db('npg_qc::Schema',
                                             't/data/qc_outcomes/fixtures');

local $ENV{NPG_CACHED_SAMPLESHEET_FILE} =
  't/data/novaseq/180709_A00538_0010_BH3FCMDRXX/' .
  'Data/Intensities/BAM_basecalls_20180805-013153/' .
  'metadata_cache_26291/samplesheet_26291.csv';

my $pkg = 'npg_pipeline::function::product_delivery_notifier';
use_ok($pkg);

my $id_run         = 26291;
my $runfolder_path = 't/data/novaseq/180709_A00538_0010_BH3FCMDRXX';
my $archive_path   = "$runfolder_path/Data/Intensities/" .
                     'BAM_basecalls_20180805-013153/no_cal/archive';
my $timestamp      = '20180701-123456';
my $customer       = 'test_customer';

my $msg_host        = 'test_msg_host';
my $msg_port        = 5672;
my $msg_vhost       = 'test_msg_vhost';
my $msg_exchange    = 'test_msg_exchange';
my $msg_routing_key = 'test_msg_routing_key';

my $config_path    = 't/data/release/config/notify_on';
my $message_config = "$config_path/npg_message_queue.conf";

subtest 'message_config' => sub {
  plan tests => 1;

  my $notifier = $pkg->new
    (conf_path           => "t/data/release/config/notify_on",
     id_run              => $id_run,
     runfolder_path      => $runfolder_path,
     timestamp           => $timestamp,
     qc_schema           => $qc);

  my $expected_config = sprintf q{%s/.npg/psd_production_events.conf},
    $ENV{HOME};
  my $observed_config = $notifier->message_config();
  is($observed_config, $expected_config,
     "Messaging config file is $expected_config") or
       diag explain $observed_config;
};

subtest 'create' => sub {
  plan tests => 9;

  my $notifier;
  lives_ok {
    $notifier = $pkg->new
      (conf_path           => $config_path,
       id_run              => $id_run,
       message_config      => $message_config,
       runfolder_path      => $runfolder_path,
       timestamp           => $timestamp,
       qc_schema           => $qc);
  } 'notifier created ok';

  my @defs = @{$notifier->create};
  my $num_defs_observed = scalar @defs;
  my $num_defs_expected = 2; # Only 2 pass manual QC, tag index 3 and 9
  cmp_ok($num_defs_observed, '==', $num_defs_expected,
         "create returns $num_defs_expected definitions when notifying");

  my @notified_rpts;
  foreach my $def (@defs) {
    push @notified_rpts,
      [map { [$_->id_run, $_->position, $_->tag_index] }
       $def->composition->components_list];
  }

  is_deeply(\@notified_rpts,
            [[[26291, 1, 3], [26291, 2, 3]],
             [[26291, 1, 9], [26291, 2, 9]]],
            'Only "26291:1:3;26291:2:3" and "26291:1:9;26291:2:9" notified')
    or diag explain \@notified_rpts;

  my $cmd_patt = qr|^/.*/npg_pipeline_notify_delivery --config $config_path/npg_message_queue.conf $archive_path/[.][.]/[.][.]/messages/26291#[3,9][.]msg[.]json|;

  foreach my $def (@defs) {
    is($def->created_by, $pkg, "created_by is $pkg");
    is($def->identifier, 26291, "identifier is set correctly");

    my $cmd = $def->command;
    like($cmd, $cmd_patt, "$cmd matches $cmd_patt") or diag explain $cmd;
  }

};

subtest 'no_message_study' => sub {
  plan tests => 2;

  my $notifier = $pkg->new
    (conf_path           => "t/data/release/config/notify_off",
     id_run              => $id_run,
     message_config      => $message_config,
     runfolder_path      => $runfolder_path,
     timestamp           => $timestamp,
     qc_schema           => $qc);

  my @defs = @{$notifier->create};
  my $num_defs_observed = scalar @defs;
  my $num_defs_expected = 1;
  cmp_ok($num_defs_observed, '==', $num_defs_expected,
         "create returns $num_defs_expected definition") or
           diag explain \@defs;

  is($defs[0]->composition, undef, 'definition has no composition') or
    diag explain \@defs;
};