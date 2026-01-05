#!/usr/bin/env groovy

/*
 * Copyright (c) 2019-2025 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

library 'status-jenkins-lib@v1.9.33'

pipeline {
  agent {
    dockerfile {
      label 'linuxcontainer'
      filename 'docker/Dockerfile.hive'
      args '-v /var/run/docker.sock:/var/run/docker.sock -u root'
    }
  }

  parameters {
    string(
      name: 'SIMULATION_NAME',
      defaultValue: 'ethereum/sync',
      description: 'The name of the simulation to run'
    )
    string(
      name: 'CLIENT_TAG',
      defaultValue: 'master',
      description: 'The tag/branch for the client build'
    )
    string(
      name: 'DOCKERFILE_TYPE',
      defaultValue: '',
      description: 'The dockerfile type (git) or leave empty to avoid rebuild'
    )
    string(
      name: 'PARALLELISM',
      defaultValue: '40',
      description: 'Number of parallel processes to run'
    )
    string(
      name: 'TIMEOUT_MINUTES',
      defaultValue: '20',
      description: 'Timeout for each stage in minutes'
    )
    booleanParam(
      name: 'DOCKER_BUILDOUTPUT',
      defaultValue: true,
      description: 'Whether to output Docker build logs'
    )
  }

  options {
    disableRestartFromStage()
    timestamps()
    ansiColor('xterm')
    timeout(time: 24, unit: 'HOURS')
    buildDiscarder(logRotator(
      numToKeepStr: '5',
      daysToKeepStr: '30',
      artifactNumToKeepStr: '3',
    ))
  }

  stages {
    stage('Run Hive Tests') {
      parallel {
        stage('sync neth-nimbus') {
          steps {
            timeout(time: params.TIMEOUT_MINUTES.toInteger(), unit: 'MINUTES') {
              sh """
                cd /opt/hive && ./hive \
                --sim "${params.SIMULATION_NAME}" \
                --client-file="${WORKSPACE}/ci/neth-nimbus-sync-config.yml" \
                --sim.parallelism=${params.PARALLELISM} \
                --sim.loglevel 4 \
                --docker.nocache hive/clients/nimbus-el \
                --docker.pull true \
                ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
              """
            }
          }
        }
        stage('sync reth-nimbus') {
          steps {
            timeout(time: params.TIMEOUT_MINUTES.toInteger(), unit: 'MINUTES') {
              sh """
                cd /opt/hive && ./hive \
                --sim "${params.SIMULATION_NAME}" \
                --client-file="${WORKSPACE}/ci/reth-nimbus-sync-config.yml" \
                --sim.parallelism=${params.PARALLELISM} \
                --sim.loglevel 4 \
                --docker.nocache hive/clients/nimbus-el \
                --docker.pull true \
                ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
              """
            }
          }
        }
        stage('sync erigon-nimbus') {
          steps {
            timeout(time: params.TIMEOUT_MINUTES.toInteger(), unit: 'MINUTES') {
              sh """
                cd /opt/hive && ./hive \
                --sim "${params.SIMULATION_NAME}" \
                --client-file="${WORKSPACE}/ci/erigon-nimbus-sync-config.yml" \
                --sim.parallelism=${params.PARALLELISM} \
                --sim.loglevel 4 \
                --docker.nocache hive/clients/nimbus-el \
                --docker.pull true \
                ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
              """
            }
          }
        }
      }
    }
  }

  post {
    success { script { github.notifyPR(true) } }
    failure { script { github.notifyPR(false) } }
    always {
      archiveArtifacts artifacts: 'simulation-results/**', allowEmptyArchive: true
      sshagent(credentials: ['jenkins-ssh']) {
        sh '''
          if [ -d /opt/hive/workspace/logs ]; then
            scp -r /opt/hive/workspace/logs/* \
              jenkins@node-01.he-eu-hel1.ci.hive.status.im:/home/jenkins/hive/workspace/logs/ || true
          fi
        '''
      }
    }
    cleanup { sh './scripts/hive-cleanup.sh || true' }
  }
}
