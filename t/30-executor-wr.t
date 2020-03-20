use strict;
use warnings;
use Test::More tests => 8;
use Test::Exception;
use File::Temp qw(tempdir);
use Graph::Directed;
use Log::Log4perl qw(:levels);
use Perl6::Slurp;
use JSON qw(from_json to_json);

use_ok('npg_pipeline::product');
use_ok('npg_pipeline::function::definition');
use_ok('npg_pipeline::executor::wr');

my $tmp = tempdir(CLEANUP => 1);

Log::Log4perl->easy_init({layout => '%d %-5p %c - %m%n',
                          level  => $DEBUG,
                          file   => join(q[/], $tmp, 'logfile'),
                          utf8   => 1});

subtest 'object creation' => sub {
  plan tests => 1;

  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {},
    function_graph       => Graph::Directed->new());
  isa_ok ($e, 'npg_pipeline::executor::wr');
};

subtest 'wr conf file' => sub {
  plan tests => 5;
  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {},
    function_graph       => Graph::Directed->new());
  my $conf = $e->wr_conf;
  is (ref $conf, 'HASH', 'configuration is a hash ref');
  while (my ($key, $value) = each %{$conf}) {
    if ( $key =~ /queue\Z/ ) {
      is_deeply ($value,
      $key =~ /\Ap4stage1/ ? {'cloud_flavor' => 'ukb1.2xlarge'} : {},
      "correct settings for $key");
    }
  }
};

subtest 'wr add command' => sub {
  plan tests => 6;

  my $get_env = sub {
    my @env = ();
    for my $name (sort qw/PATH PERL5LIB IRODS_ENVIRONMENT_FILE
                          CLASSPATH NPG_CACHED_SAMPLESHEET_FILE
                          NPG_REPOSITORY_ROOT/) {
      my $v = $ENV{$name};
      if ($v) {
        push @env, join(q[=], $name, $v);
      }
    }
    my $env_string = join q[,], @env;
    return q['] . $env_string . q['];
  }; 
 
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = q[];
  my $env_string = $get_env->();
  unlike  ($env_string, qr/NPG_CACHED_SAMPLESHEET_FILE/,
    'env does not contain samplesheet');
  my $file = "$tmp/commands.txt";
  my $e = npg_pipeline::executor::wr->new(
    function_definitions    => {},
    function_graph          => Graph::Directed->new(),
    commands4jobs_file_path => $file);
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');

  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = 't/data/samplesheet_1234.csv';
  $env_string = $get_env->();
  like  ($env_string, qr/NPG_CACHED_SAMPLESHEET_FILE/,
    'env contains samplesheet');
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');
  local $ENV{NPG_REPOSITORY_ROOT} = 't/data';
  $env_string = $get_env->();
  like  ($env_string, qr/NPG_REPOSITORY_ROOT/, 'env contains ref repository');
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');
};

subtest 'definition for a job' => sub {
  plan tests => 5;

  my $ref = {
    created_by    => __PACKAGE__,
    created_on    => 'today',
    identifier    => 1234,
    job_name      => 'job_name',
    command       => '/bin/true',
    num_cpus      => [1],
    queue         => 'small'
  };
  my $fd = npg_pipeline::function::definition->new($ref);

  my $g = Graph::Directed->new();
  $g->add_edge('pipeline_wait4path', 'pipeline_start');
  $g->add_edge('archival_to_irods_ml_warehouse', 'pipeline_wait4path');

  my $conf_dir = join q[/], $tmp, 'conf_files';
  mkdir $conf_dir or die "Failed to create directory $conf_dir";
  my $conf_file = join q[/], $conf_dir, 'wr.json';
  my $conf = {
    "default_queue" => {},
    "small_queue" => {},
    "lowload_queue" => {},
    "p4stage1_queue" => {"cloud_flavor" => "best"}
  };

  my $create_conf = sub {
    my $content = shift;
    open my $fh, q[>], $conf_file or die "Failed to open $conf_file for writing";
    print $fh to_json($content) or die "Failed to print to $conf_file";
    close $fh or warn "Failed to close $conf_file";
  };
  
  $create_conf->($conf);

  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {
      'pipeline_wait4path'             => [$fd],
      'pipeline_start'                 => [$fd],
      'archival_to_irods_ml_warehouse' => [$fd]
    },
    function_graph       => $g,
    conf_path            => $conf_dir
  );

  my $job_def = $e->_definition4job('pipeline_wait4path', 'some_dir', $fd);
  my $expected = { 'cmd' => '(umask 0002 && /bin/true ) 2>&1',
                   'cpus' => 1,
                   'priority' => 0,
                   'memory' => '2000M' };
  is_deeply ($job_def, $expected, 'job definition without tee-ing to a log file');

  $ref->{'num_cpus'} = [0];
  $ref->{'memory'}   = 100;
  $fd = npg_pipeline::function::definition->new($ref);
  $expected = {
    'cmd' => '(umask 0002 && /bin/true ) 2>&1 | tee -a "some_dir/pipeline_start-today-1234.out"',
    'cpus' => 0,
    'priority' => 0,
    'memory'   => '100M' };
  $job_def = $e->_definition4job('pipeline_start', 'some_dir', $fd);
  is_deeply ($job_def, $expected, 'job definition with tee-ing to a log file');

  $ref->{'chunk'} = 1;
  $fd = npg_pipeline::function::definition->new($ref);
  $expected = {
    'cmd' => '(umask 0002 && /bin/true ) 2>&1 | tee -a "some_dir/pipeline_start-today-1234.1.out"',
    'cpus' => 0,
    'priority' => 0,
    'memory'   => '100M' };
  $job_def = $e->_definition4job('pipeline_start', 'some_dir', $fd);
  is_deeply ($job_def, $expected, 'chunked job definition with tee-ing to a log file');

  delete $ref->{'chunk'};
  $fd = npg_pipeline::function::definition->new($ref);
  $expected = {
    'cmd' => '(umask 0002 && /bin/true ) 2>&1 | tee -a "some_dir/archival_to_irods_ml_warehouse-today-1234.out"',
    'cpus' => 0,
    'priority' => 0,
    'memory'   => '100M',
    'limit_grps' => 'archival2irods:3' };
  $job_def = $e->_definition4job('archival_to_irods_ml_warehouse', 'some_dir', $fd);
  is_deeply ($job_def, $expected, 'default group limit for archival to irods');

  $conf->{archival2irods_limit_grps} = 5;
  $create_conf->($conf);
  $e = npg_pipeline::executor::wr->new(
    function_definitions => {
      'pipeline_wait4path'             => [$fd],
      'pipeline_start'                 => [$fd],
      'archival_to_irods_ml_warehouse' => [$fd]
    },
    function_graph       => $g,
    conf_path            => $conf_dir
  );
  $expected->{limit_grps} = 'archival2irods:5';
  $job_def = $e->_definition4job('archival_to_irods_ml_warehouse', 'some_dir', $fd);
  is_deeply ($job_def, $expected, 'group limit for archival to irods from the config file'); 
};

subtest 'dependencies' => sub {
  plan tests => 85;

  my $g = Graph::Directed->new();
  $g->add_edge('pipeline_start', 'function1');
  $g->add_edge('pipeline_start', 'function2');
  $g->add_edge('function1', 'function3');
  $g->add_edge('function2', 'function3');
  $g->add_edge('function3', 'function4');
  $g->add_edge('function2', 'function5');
  $g->add_edge('function5', 'function6');
  $g->add_edge('function4', 'pipeline_end');
  $g->add_edge('function6', 'pipeline_end');

  my $ref = {
    created_by    => 'test',
    created_on    => 'today',
    identifier    => 'my_id',
    job_name      => 'job_name',
    command       => '/bin/true',
  };
  my $fd = npg_pipeline::function::definition->new($ref);
  
  my $definitions = {'pipeline_start' => [$fd], 'pipeline_end' => [$fd]};

  $definitions->{'function1'} = [
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1')->composition)
                                 ];

  $definitions->{'function2'} = [
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:1')->composition),
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:2')->composition)
                                 ];

  $definitions->{'function3'} =  $definitions->{'function2'};

  $definitions->{'function4'} =  [(
    @{$definitions->{'function3'}},
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:3')->composition)
                                  )];

  $definitions->{'function5'} = [
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:1')->composition),
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:1')->composition),
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:2')->composition),
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:2')->composition)
                                 ];

  $definitions->{'function6'} =  $definitions->{'function2'};

  my $file = "$tmp/wr_input.json";
  my $e = npg_pipeline::executor::wr->new(
    function_definitions => $definitions,
    function_graph       => $g,
    interactive          => 1,
    commands4jobs_file_path => $file
  );
  
  lives_ok { $e->execute() } 'runs OK';
  my @lines = slurp $file;
    #########################
    # Example of output file
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/pipeline_start/pipeline_start-today-my_id.out\"","dep_grps":["pipeline_start-my_id-3987079762","pipeline_start-my_id-3987079762-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-pipeline_start"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function2/function2-today-2345:1:1.out\"","dep_grps":["function2-my_id-2434227795","function2-my_id-2434227795-0"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function2"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function2/function2-today-2345:1:2.out\"","dep_grps":["function2-my_id-2434227795","function2-my_id-2434227795-1"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function2"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function1/function1-today-2345:1.out\"","dep_grps":["function1-my_id-1848022402","function1-my_id-1848022402-0"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function1"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function3/function3-today-2345:1:1.out\"","dep_grps":["function3-my_id-113545543","function3-my_id-113545543-0"],"deps":["function1-my_id-1848022402","function2-my_id-2434227795-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-function3"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function3/function3-today-2345:1:2.out\"","dep_grps":["function3-my_id-113545543","function3-my_id-113545543-1"],"deps":["function1-my_id-1848022402","function2-my_id-2434227795-1"],"memory":"2000M","priority":0,"rep_grp":"my_id-function3"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:1.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-0"],"deps":["function3-my_id-113545543-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:2.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-1"],"deps":["function3-my_id-113545543-1"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:3.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-2"],"deps":["function3-my_id-113545543"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/pipeline_end/pipeline_end-today-my_id.out\"","dep_grps":["pipeline_end-my_id-3260187172","pipeline_end-my_id-3260187172-0"],"deps":["function4-my_id-2369338210"],"memory":"2000M","priority":0,"rep_grp":"my_id-pipeline_end"}
    #########################

  my @obj_lines = map { from_json $_ } @lines;
  my @pipl_end_lines = grep { $_->{'rep_grp'} eq 'my_id-pipeline_end' } @obj_lines; # pipeline_end
  is (scalar @pipl_end_lines, 1, 'pipeline_end - one job');
  my $h = pop @pipl_end_lines;
  ok ($h->{"dep_grps"} && $h->{"deps"}, 'pipeline_end - dependencies keys present');
  is (scalar @{$h->{"dep_grps"}}, 2, 'pipeline_end - two groups are defined for the job');
  like ($h->{"dep_grps"}->[0], qr/\Apipeline_end-my_id-\d+\Z/, 'pipeline_end - generic group');
  is ($h->{"dep_grps"}->[1], $h->{"dep_grps"}->[0] . '-0', 'pipeline_end - specific group');
  is (scalar @{$h->{"deps"}}, 2, 'depends on two jobs');
  like ($h->{"deps"}->[0], qr/\Afunction[46]-my_id-\d+\Z/, 'pipeline_end - dependency is generic');
  like ($h->{"deps"}->[1], qr/\Afunction[46]-my_id-\d+\Z/, 'pipeline_end - dependency is generic');

  #function 6
  my @func6_lines = grep { $_->{'rep_grp'} eq 'my_id-function6' } @obj_lines;
  for my $id (qw/1 0/) {
    $h = pop @func6_lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'function 6 - dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'function 6 - two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction6-my_id-\d+\Z/, 'function 6 - generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'function 6 - specific group');
    is (scalar @{$h->{"deps"}}, 2, 'function 6 - depends on two jobs');
    my $i = 0;
    my $j = 1;
    like ($h->{"deps"}->[$i], qr/\Afunction5-my_id-\d+-[02]\Z/, 'function 6 - dependency is specific');
    like ($h->{"deps"}->[$j], qr/\Afunction5-my_id-\d+-[13]\Z/, 'function 6 - dependency is specific');
  }

  #function 5
  my @func5_lines = grep { $_->{'rep_grp'} eq 'my_id-function5' } @obj_lines;
  for my $id (qw/3 2 1 0/) {
    $h = pop @func5_lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'function 5 - dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'function 5 - two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction5-my_id-\d+\Z/, 'function 5 - generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'function 5 - specific group');
    is (scalar @{$h->{"deps"}}, 1, 'function 5 - depends on one job');
    my $i = 0;
    my $j = 1;
    like ($h->{"deps"}->[0], qr/\Afunction2-my_id-\d+-[01]\Z/, 'function 5 - dependency is specific');
  }

  #function 4
  my @func4_lines = grep { $_->{'rep_grp'} eq 'my_id-function4' } @obj_lines;
  for my $id (qw/2 1 0/) {
    $h = pop @func4_lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction4-my_id-\d+\Z/, 'generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'specific group');
    is (scalar @{$h->{"deps"}}, 1, 'depends on one job');
    if ($id eq '2') {
      like ($h->{"deps"}->[0], qr/\Afunction3-my_id-\d+\Z/, 'dependency is generic');
    } else {
      like ($h->{"deps"}->[0], qr/\Afunction3-my_id-\d+-$id\Z/, 'dependency is specific');
    }
  }

  # function 3
  my @func3_lines = grep { $_->{'rep_grp'} eq 'my_id-function3' } @obj_lines;
  for my $id (qw/1 0/) {
    $h = pop @func3_lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction3-my_id-\d+\Z/, 'generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'specific group');
    is (scalar @{$h->{"deps"}}, 2, 'depends on two jobs');
    my $i = 0;
    my $j = 1;
    if ($h->{"deps"}->[0] =~ /function2/) {
      $i = 1;
      $j = 0;
    } 
    like ($h->{"deps"}->[$i], qr/\Afunction1-my_id-\d+\Z/, 'dependency is generic');
    like ($h->{"deps"}->[$j], qr/\Afunction2-my_id-\d+-$id\Z/, 'dependency is specific');
  }

  my @remain_lines = grep { $_->{'rep_grp'} !~ 'my_id-function[3-6]|my_id-pipeline_end' } @obj_lines;
  is (scalar @remain_lines, 4, 'four jobs remain');
  $h = shift @remain_lines;
  ok ($h->{"dep_grps"}, 'dependency groups are defined');
  ok (!exists $h->{"deps"}, 'the job does not depend on any other job');
  is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
  like ($h->{"dep_grps"}->[0], qr/\Apipeline_start-my_id-\d+\Z/, 'generic group');
  is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],0), 'specific group')
};

1;
