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
            script {
              try {
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
              } catch (e) {
                env.FAILED_NETH_NIMBUS = 'true'
                throw e
              }
            }
          }
        }
        stage('sync reth-nimbus') {
          steps {
            script {
              try {
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
              } catch (e) {
                env.FAILED_RETH_NIMBUS = 'true'
                throw e
              }
            }
          }
        }
        stage('sync erigon-nimbus') {
          steps {
            script {
              try {
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
              } catch (e) {
                env.FAILED_ERIGON_NIMBUS = 'true'
                throw e
              }
            }
          }
        }
      }
    }
  }

  post {
    success { script { github.notifyPR(true) } }
    failure {
      script {
        github.notifyPR(true)
        if (env.CHANGE_ID) {
          def failedStages = []
          if (env.FAILED_NETH_NIMBUS) failedStages.add('neth-nimbus')
          if (env.FAILED_RETH_NIMBUS) failedStages.add('reth-nimbus')
          if (env.FAILED_ERIGON_NIMBUS) failedStages.add('erigon-nimbus')
          def failedList = failedStages.join(', ') ?: 'unknown'
          withCredentials([string(credentialsId: 'discord-hive-webhook', variable: 'DISCORD_WEBHOOK_URL')]) {
            sh """
              curl -s -H "Content-Type: application/json" -X POST "\${DISCORD_WEBHOOK_URL}" -d '{
                "embeds": [{
                  "title": "Hive Test Failure",
                  "description": "Hive tests failed for [PR-${env.CHANGE_ID}](https://github.com/status-im/nimbus-eth1/pull/${env.CHANGE_ID})",
                  "color": 15158332,
                  "fields": [
                    {"name": "Branch", "value": "[${env.CHANGE_BRANCH}](https://github.com/status-im/nimbus-eth1/tree/${env.CHANGE_BRANCH})", "inline": true},
                    {"name": "Build", "value": "[#${env.BUILD_NUMBER}](https://ci.status.im/blue/organizations/jenkins/nimbus-eth1%2Fplatforms%2Flinux%2Fx86_64%2Fhive/detail/PR-${env.CHANGE_ID}/${env.BUILD_NUMBER}/pipeline/)", "inline": true},
                    {"name": "Simulation", "value": "${params.SIMULATION_NAME}", "inline": true},
                    {"name": "Failed Stages", "value": "[${failedList}](https://hive.nimbus.team/#summary-sort=name&suite=sync)", "inline": false}
                  ]
                }]
              }'
            """
          }
        }
      }
    }
    always {
      archiveArtifacts artifacts: 'simulation-results/**', allowEmptyArchive: true
      sshagent(credentials: ['jenkins-ssh']) {
        sh '''
          if [ -d /opt/hive/workspace/logs ]; then
            scp -o StrictHostKeyChecking=no -r /opt/hive/workspace/logs/* \
              jenkins@node-01.he-eu-hel1.ci.hive.status.im:/home/jenkins/hive/workspace/logs/
          fi
        '''
      }
    }
    cleanup { sh './scripts/hive-cleanup.sh || true' }
  }
}
