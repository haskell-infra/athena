#!/usr/bin/env bash

function do_ssh {
  sshpass -p $1 ssh -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no     \
      -q \
      $2 $3
}

function do_scp {
  sshpass -p $1 scp -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no     \
      -q \
      $2 $3
}

function do_scp_dir {
  sshpass -p $1 scp -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no     \
      -q \
      -r $2 $3
}
