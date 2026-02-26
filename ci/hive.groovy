#!/usr/bin/env groovy

/*
 * Copyright (c) 2019-2026 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

library 'status-jenkins-lib@v1.9.33'

def failedStages = []

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
      name: 'PARALLELISM',
      defaultValue: '40',
      description: 'Number of parallel processes to run'
    )
    string(
      name: 'TIMEOUT_MINUTES',
      defaultValue: '40',
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
    stage('Build nimbus-eth1') {
      steps {
        sh 'docker build -f "${WORKSPACE}/Dockerfile" "${WORKSPACE}"'
      }
    }
    stage('Prepare Hive') {
      steps {
        sh """
          git clone --depth 1 https://github.com/ethereum/hive.git ${WORKSPACE}/hive
          cd ${WORKSPACE}/hive
          go build -o hive .
        """
      }
    }
    stage('Run Hive Tests') {
      parallel {
        stage('sync neth-nimbus') {
          options {
            timeout(time: params.TIMEOUT_MINUTES, unit: 'MINUTES')
          }
          steps {
            script {
              try {
                dir('hive') {
                  sh """
                    ./hive \
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
                failedStages << env.STAGE_NAME
                throw e
              }
            }
          }
        }
        stage('sync reth-nimbus') {
          options {
            timeout(time: params.TIMEOUT_MINUTES, unit: 'MINUTES')
          }
          steps {
            script {
              try {
                dir('hive') {
                  sh """
                    ./hive \
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
                failedStages << env.STAGE_NAME
                throw e
              }
            }
          }
        }
        stage('sync erigon-nimbus') {
          options {
            timeout(time: params.TIMEOUT_MINUTES, unit: 'MINUTES')
          }
          steps {
            script {
              try {
                dir('hive') {
                  sh """
                    ./hive \
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
                failedStages << env.STAGE_NAME
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
        if (!env.CHANGE_ID) { return }
        withCredentials([string(credentialsId: 'discord-hive-webhook', variable: 'DISCORD_WEBHOOK_URL')]) {
          withEnv([
            "FAILED_STAGES=${failedStages.join(', ') ?: 'unknown'}",
            "SIMULATION_NAME=${params.SIMULATION_NAME}"
          ]) {
            sh './scripts/hive-notify-discord.sh'
          }
        }
      }
    }
    always {
      archiveArtifacts artifacts: 'simulation-results/**', allowEmptyArchive: true
      sshagent(credentials: ['jenkins-ssh']) {
        sh './scripts/hive-upload-logs.sh'
      }
    }
    cleanup {
      sh './scripts/hive-cleanup.sh'
      sh 'rm -rf ${WORKSPACE}/hive'
    }
  }
}
