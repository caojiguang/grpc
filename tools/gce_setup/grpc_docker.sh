#!/bin/bash
#
# Contains funcs that help maintain GRPC's Docker images.
#
# Most funcs rely on the special-purpose GCE instance to build the docker
# instances and store them in a GCS-backed docker repository.
#
# The GCE instance
# - should be based on the container-optimized GCE instance
# [https://cloud.google.com/compute/docs/containers].
# - should be running google/docker-registry image
# [https://registry.hub.docker.com/u/google/docker-registry/], so that images
# can be saved to GCS
# - should have the GCE support scripts from this directory install on it.
#
# The expected workflow is
# - start a grpc docker GCE instance
#  * on startup, some of the docker images will be regenerated automatically
# - used grpc_update_image to update images via that instance

# Pushes a dockerfile dir to cloud storage.
#
# dockerfile is expected to the parent directory to a nunber of directoies each
# of which specifies a Dockerfiles.
#
# grpc_push_dockerfiles path/to/docker_parent_dir gs://bucket/path/to/gcs/parent
grpc_push_dockerfiles() {
  local docker_dir=$1
  [[ -n $docker_dir ]] || {
    echo "$FUNCNAME: missing arg: docker_dir" 1>&2
    return 1
  }

  local gs_root_uri=$2
  [[ -n $gs_root_uri ]] || {
    echo "$FUNCNAME: missing arg: gs_root_uri" 1>&2
    return 1
  }

  find $docker_dir -name '*~' -o -name '#*#' -exec rm -fv {} \; || {
    echo "$FUNCNAME: failed: cleanup of tmp files in $docker_dir" 1>&2
    return 1
  }
  gsutil cp -R $docker_dir $gs_root_uri || {
    echo "$FUNCNAME: failed: cp $docker_dir -> $gs_root_uri" 1>&2
    return 1
  }
}

# Adds the user to docker group on a GCE instance, and restarts the docker
# daemon
grpc_add_docker_user() {
  local host=$1
  [[ -n $host ]] || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }

  local project=$2
  local project_opt=''
  [[ -n $project ]] && project_opt=" --project $project"

  local zone=$3
  local zone_opt=''
  [[ -n $zone ]] && zone_opt=" --zone $zone"


  local func_lib="/var/local/startup_scripts/shared_startup_funcs.sh"
  local ssh_cmd="source $func_lib && grpc_docker_add_docker_group"
  gcloud compute $project_opt ssh $zone_opt $host --command "$ssh_cmd"
}

# Updates a docker image specified in a local dockerfile via the docker
# container GCE instance.
#
# the docker container GCE instance
# - should have been setup using ./new_grpc_docker_instance
# - so will have /var/local/startup_scripts/shared_startup_funcs.sh, a copy of
#   ./shared_startup_funcs.sh
#
# grpc_update_image gs://bucket/path/to/dockerfile parent \.
#   image_label path/to/docker_dir docker_gce_instance [project] [zone]
grpc_update_image() {
  local gs_root_uri=$1
  [[ -n $gs_root_uri ]] || {
    echo "$FUNCNAME: missing arg: gs_root_uri" 1>&2
    return 1
  }

  local image_label=$2
  [[ -n $image_label ]] || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }

  local docker_dir=$3
  [[ -n $docker_dir ]] || {
    echo "$FUNCNAME: missing arg: docker_dir" 1>&2
    return 1
  }
  [[ -d $docker_dir ]] || {
    echo "could find directory $docker_dir" 1>&2
    return 1
  }
  local docker_parent_dir=$(dirname $docker_dir)
  local gce_docker_dir="/var/local/dockerfile/$(basename $docker_dir)"

  local host=$4
  [[ -n $host ]] || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }

  local project=$5
  local project_opt=''
  [[ -n $project ]] && project_opt=" --project $project"

  local zone=$6
  local zone_opt=''
  [[ -n $zone ]] && zone_opt=" --zone $zone"

  local func_lib="/var/local/startup_scripts/shared_startup_funcs.sh"
  local ssh_cmd="source $func_lib"
  local ssh_cmd+=" && grpc_dockerfile_refresh $image_label $gce_docker_dir"

  grpc_push_dockerfiles $docker_parent_dir $gs_root_uri || return 1
  gcloud compute $project_opt ssh $zone_opt $host --command "$ssh_cmd"
}

# gce_has_instance checks if a project contains a named instance
#
# gce_has_instance <project> <instance_name>
gce_has_instance() {
  local project=$1
  [[ -n $project ]] || { echo "$FUNCNAME: missing arg: project" 1>&2; return 1; }
  local checked_instance=$2
  [[ -n $checked_instance ]] || {
    echo "$FUNCNAME: missing arg: checked_instance" 1>&2
    return 1
  }

  instances=$(gcloud --project $project compute instances list \
    | sed -e 's/ \+/ /g' | cut -d' ' -f 1)
  for i in $instances
  do
    if [[ $i == $checked_instance ]]
    then
      return 0
    fi
  done

  echo "instance '$checked_instance' not found in compute project $project" 1>&2
  return 1
}

# gce_find_internal_ip finds the ip address of a instance if it is present in
# the project.
#
# gce_find_internal_ip <project> <instance_name>
gce_find_internal_ip() {
  local project=$1
  [[ -n $project ]] || { echo "$FUNCNAME: missing arg: project" 1>&2; return 1; }
  local checked_instance=$2
  [[ -n $checked_instance ]] || {
    echo "$FUNCNAME: missing arg: checked_instance" 1>&2
    return 1
  }

  gce_has_instance $project $checked_instance || return 1
  gcloud --project $project compute instances list \
    | grep -e "$checked_instance\s" \
    | sed -e 's/ \+/ /g' | cut -d' ' -f 4
}

# sets the vars grpc_zone and grpc_project
#
# to be used in funcs that want to set the zone and project and potential
# override them with
#
# grpc_zone
# - is set to the value gcloud config value for compute/zone if that's present
# - it defaults to asia-east1-a
# - it can be overridden by passing -z <other value>
#
# grpc_project
# - is set to the value gcloud config value for project if that's present
# - it defaults to stoked-keyword-656 (the grpc cloud testing project)
# - it can be overridden by passing -p <other value>
grpc_set_project_and_zone() {
  dry_run=0
  grpc_zone=$(gcloud config list compute/zone --format text \
    | sed -e 's/ \+/ /g' | cut -d' ' -f 2)
  # pick a known zone as a default
  [[ $grpc_zone == 'None' ]] && grpc_zone='asia-east1-a'

  grpc_project=$(gcloud config list project --format text \
    | sed -e 's/ \+/ /g' | cut -d' ' -f 2)
  # pick an known zone as a default
  [[ $grpc_project == 'None' ]] && grpc_project='stoked-keyword-656'

  # see if -p or -z is used to override the the project or zone
  local OPTIND
  local OPTARG
  local arg_func
  while getopts :p:z:f:n name
  do
    case $name in
      f)   declare -F $OPTARG >> /dev/null && {
          arg_func=$OPTARG;
        } || {
          echo "-f: arg_func value: $OPTARG is not defined"
          return 2
        }
        ;;
      n)   dry_run=1 ;;
      p)   grpc_project=$OPTARG ;;
      z)   grpc_zone=$OPTARG ;;
      :)   [[ $OPT_ARG == 'f' ]] && {
          echo "-f: arg_func provided" 1>&2
          return 2
        } || {
          # ignore -p or -z without args, just use the defaults
          continue
        }
        ;;
      \?)  echo "-$OPTARG: unknown flag; it's ignored" 1>&2;  continue ;;
    esac
  done
  shift $((OPTIND-1))
  [[ -n $arg_func ]] && $arg_func "$@"
}

# construct the flags to be passed to the binary running the test client
#
# call-seq:
#   flags=$(grpc_interop_test_flags <server_ip> <server_port> <test_case>)
#   [[ -n flags ]] || return 1
grpc_interop_test_flags() {
  [[ -n $1 ]] && {  # server_ip
    local server_ip=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: server_ip" 1>&2
    return 1
  }
  [[ -n $1 ]] && {  # port
    local port=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: port" 1>&2
    return 1
  }
  [[ -n $1 ]] && {  # test_case
    local test_case=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: test_case" 1>&2
    return 1
  }
  echo "--server_host=$server_ip --server_port=$port --test_case=$test_case"
}

# checks the positional args and assigns them to variables visible in the caller
#
# these are the positional args passed to grpc_interop_test after option flags
# are removed
#
# five args are expected, in order
# - test_case
# - host <the gce docker instance on which to run the test>
# - client to run
# - server_host <the gce docker instance on which the test server is running>
# - server type
grpc_interop_test_args() {
  [[ -n $1 ]] && {  # test_case
    test_case=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: test_case" 1>&2
    return 1
  }

  [[ -n $1 ]] && {  # host
    host=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }

  [[ -n $1 ]] && {  # client_type
    case $1 in
      cxx|go|java|nodejs|php|python|ruby)
        grpc_gen_test_cmd="grpc_interop_gen_$1_cmd"
        declare -F $grpc_gen_test_cmd >> /dev/null || {
          echo "-f: test_func for $1 => $grpc_gen_test_cmd is not defined" 1>&2
          return 2
        }
        shift
        ;;
      *)
        echo "bad client_type: $1" 1>&2
        return 1
        ;;
    esac
  } || {
    echo "$FUNCNAME: missing arg: client_type" 1>&2
    return 1
  }

  [[ -n $1 ]] && {  # grpc_server
    grpc_server=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: grpc_server" 1>&2
    return 1
  }

  [[ -n $1 ]] && {  # server_type
    case $1 in
      cxx)    grpc_port=8010 ;;
      go)     grpc_port=8020 ;;
      java)   grpc_port=8030 ;;
      nodejs) grpc_port=8040 ;;
      python) grpc_port=8050 ;;
      ruby)   grpc_port=8060 ;;
      *) echo "bad server_type: $1" 1>&2; return 1 ;;
    esac
    shift
  } || {
    echo "$FUNCNAME: missing arg: server_type" 1>&2
    return 1
  }
}

grpc_update_docker_images_args() {
  [[ -n $1 ]] && {  # host
    host=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }
}

# Updates all the known docker images on a host..
#
# call-seq;
#   grpc_update_docker_images <server_name>
#
# Updates the GCE docker instance <server_name>
grpc_update_docker_images() {
  # declare vars local so that they don't pollute the shell environment
  # where they this func is used.
  local grpc_zone grpc_project dry_run  # set by grpc_set_project_and_zone
  # set by grpc_update_docker_images_args
  local host

  # set the project zone and check that all necessary args are provided
  grpc_set_project_and_zone -f grpc_update_docker_images_args "$@" || return 1
  gce_has_instance $grpc_project $host || return 1;

  local func_lib="/var/local/startup_scripts/shared_startup_funcs.sh"
  local cmd="source $func_lib && grpc_docker_pull_known"
  local project_opt="--project $grpc_project"
  local zone_opt="--zone $grpc_zone"
  local ssh_cmd="bash -l -c \"$cmd\""
  echo "will run:"
  echo "  $ssh_cmd"
  echo "on $host"
  [[ $dry_run == 1 ]] && return 0  # don't run the command on a dry run
  gcloud compute $project_opt ssh $zone_opt $host --command "$cmd"
}

grpc_launch_server_args() {
  [[ -n $1 ]] && {  # host
    host=$1
    shift
  } || {
    echo "$FUNCNAME: missing arg: host" 1>&2
    return 1
  }

  [[ -n $1 ]] && {  # server_type
    case $1 in
      cxx)    grpc_port=8010 ;;
      go)     grpc_port=8020 ;;
      java)   grpc_port=8030 ;;
      nodejs) grpc_port=8040 ;;
      python) grpc_port=8050 ;;
      ruby)   grpc_port=8060 ;;
      *) echo "bad server_type: $1" 1>&2; return 1 ;;
    esac
    docker_label="grpc/$1"
    docker_name="grpc_interop_$1"
    shift
  } || {
    echo "$FUNCNAME: missing arg: server_type" 1>&2
    return 1
  }
}

# Launches a server on a docker instance.
#
# call-seq;
#   grpc_launch_server <server_name> <server_type>
#
# Runs the server_type on a GCE instance running docker with server_name
grpc_launch_server() {
  # declare vars local so that they don't pollute the shell environment
  # where they this func is used.
  local grpc_zone grpc_project dry_run  # set by grpc_set_project_and_zone
  # set by grpc_launch_server_args
  local docker_label docker_name host grpc_port

  # set the project zone and check that all necessary args are provided
  grpc_set_project_and_zone -f grpc_launch_server_args "$@" || return 1
  gce_has_instance $grpc_project $host || return 1;

  cmd="sudo docker run -d --name $docker_name"
  cmd+=" -p $grpc_port:$grpc_port $docker_label"
  local project_opt="--project $grpc_project"
  local zone_opt="--zone $grpc_zone"
  local ssh_cmd="bash -l -c \"$cmd\""
  echo "will run:"
  echo "  $ssh_cmd"
  echo "on $host"
  [[ $dry_run == 1 ]] && return 0  # don't run the command on a dry run
  gcloud compute $project_opt ssh $zone_opt $host --command "$cmd"
}

# Runs a test command on a docker instance.
#
# call-seq:
#   grpc_interop_test <test_name> <host> <client_type> \
#                     <server_host> <server_type>
#
# N.B:  server_name defaults to 'grpc-docker-server'
#
# requirements:
#   host is a GCE instance running docker with access to the gRPC docker images
#   server_name is a GCE docker instance running the gRPC server in docker
#   test_name is one of the named gRPC tests [http://go/grpc_interop_tests]
#   client_type is one of [cxx,go,java,php,python,ruby]
#   server_type is one of [cxx,go,java,python,ruby]
#
# it assumes:
#   that each grpc-imp has a docker image named grpc/<imp>, e.g, grpc/java
#   a test is run using $ docker run 'path/to/interop_test_bin --flags'
#   the required images are available on <host>
#
#   server_name [default:grpc-docker-server] is an instance that runs the
#   <server_type> server on the standard test port for the <server_type>
#
# each server_type runs it tests on a standard test port as follows:
#   cxx:    8010
#   go:     8020
#   java:   8030
#   nodejs: 8040
#   python: 8050
#   ruby:   8060
#
# each client_type should have an associated bash func:
#   grpc_interop_gen_<client_type>_cmd
# the func provides the dockerized commmand for running client_type's test.
# If no such func is available, tests for that client type cannot be run.
#
# the flags for running a test are the same:
#
# --server_host=<svr_addr>  --server_port=<svr_port> --test_case=<...>
grpc_interop_test() {
  # declare vars local so that they don't pollute the shell environment
  # where they this func is used.

  local grpc_zone grpc_project dry_run  # set by grpc_set_project_and_zone
  #  grpc_interop_test_args
  local test_case host grpc_gen_test_cmd grpc_server grpc_port

  # set the project zone and check that all necessary args are provided
  grpc_set_project_and_zone -f grpc_interop_test_args "$@" || return 1
  gce_has_instance $grpc_project $host || return 1;

  local addr=$(gce_find_internal_ip $grpc_project $grpc_server)
  [[ -n $addr ]] || return 1
  local flags=$(grpc_interop_test_flags $addr $grpc_port $test_case)
  [[ -n $flags ]] || return 1
  cmd=$($grpc_gen_test_cmd $flags)
  [[ -n $cmd ]] || return 1

  local project_opt="--project $grpc_project"
  local zone_opt="--zone $grpc_zone"
  local ssh_cmd="bash -l -c \"$cmd\""
  echo "will run:"
  echo "  $ssh_cmd"
  echo "on $host"
  [[ $dry_run == 1 ]] && return 0  # don't run the command on a dry run
  gcloud compute $project_opt ssh $zone_opt $host --command "$cmd"
}

# constructs the full dockerized ruby interop test cmd.
#
# call-seq:
#   flags= .... # generic flags to include the command
#   cmd=$($grpc_gen_test_cmd $flags)
grpc_interop_gen_ruby_cmd() {
  local cmd_prefix="sudo docker run grpc/ruby bin/bash -l -c"
  local test_script="/var/local/git/grpc/src/ruby/bin/interop/interop_client.rb"
  local the_cmd="$cmd_prefix 'ruby $test_script $@'"
  echo $the_cmd
}

# constructs the full dockerized java interop test cmd.
#
# call-seq:
#   flags= .... # generic flags to include the command
#   cmd=$($grpc_gen_test_cmd $flags)
grpc_interop_gen_java_cmd() {
    local cmd_prefix="sudo docker run grpc/java";
    local test_script="/var/local/git/grpc-java/run-test-client.sh";
    local test_script+=" --transport=NETTY_TLS --grpc_version=2"
    local the_cmd="$cmd_prefix $test_script $@";
    echo $the_cmd
}

# constructs the full dockerized php interop test cmd.
#
# TODO(mlumish): update this to use the script once that's on git-on-borg
#
# call-seq:
#   flags= .... # generic flags to include the command
#   cmd=$($grpc_gen_test_cmd $flags)
grpc_interop_gen_php_cmd() {
    local cmd_prefix="sudo docker run grpc/php bin/bash -l -c";
    local test_script="cd /var/local/git/grpc/src/php/tests/interop";
    local test_script+=" && php -d extension_dir=../../ext/grpc/modules/";
    local test_script+=" -d extension=grpc.so interop_client.php";
    local the_cmd="$cmd_prefix '$test_script $@ 1>&2'";
    echo $the_cmd
}


# TODO(grpc-team): add grpc_interop_gen_xxx_cmd for python|cxx|nodejs|go