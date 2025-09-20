#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.24'

pipeline {
  agent {
    agent { label 'linux-01' }
  }

  parameters {
    string(
      name: 'SIMULATION_NAME',
      defaultValue: 'ethereum/eest/consume-rlp',
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
      name: 'FIXTURES_URL',
      defaultValue: 'https://github.com/ethereum/execution-spec-tests/releases/download/pectra-devnet-6%40v1.0.0/fixtures_pectra-devnet-6.tar.gz',
      description: 'URL to the fixtures tarball'
    )
    string(
      name: 'PARALLELISM',
      defaultValue: '40',
      description: 'Number of parallel processes to run'
    )
    booleanParam(
      name: 'DOCKER_BUILDOUTPUT',
      defaultValue: true,
      description: 'Whether to output Docker build logs'
    )
  }

  stages {
    stage('sync neth-nimbus') {
      steps {
          sh """
            hive \
            --sim "${params.SIMULATION_NAME}" \
            --client-file="${WORKSPACE}/ci/neth-nimbus-sync-config.yml" \
            --sim.buildarg fixtures=${params.FIXTURES_URL} \
            --sim.parallelism=${params.PARALLELISM} \
            --sim.loglevel 4 \
            --docker.nocache hive/clients/nimbus-el \
            --docker.pull true \
            ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
          """
      }
    }
    stage('sync reth-nimbus') {
      steps {
          sh """
            hive \
            --sim "${params.SIMULATION_NAME}" \
            --client-file="${WORKSPACE}/ci/reth-nimbus-sync-config.yml" \
            --sim.buildarg fixtures=${params.FIXTURES_URL} \
            --sim.parallelism=${params.PARALLELISM} \
            --sim.loglevel 4 \
            --docker.nocache hive/clients/nimbus-el \
            --docker.pull true \
            ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
          """
      }
    }
    stage('sync erigon-nimbus') {
      steps {
          sh """
            hive \
            --sim "${params.SIMULATION_NAME}" \
            --client-file="${WORKSPACE}/ci/erigon-nimbus-sync-config.yml" \
            --sim.buildarg fixtures=${params.FIXTURES_URL} \
            --sim.parallelism=${params.PARALLELISM} \
            --sim.loglevel 4 \
            --docker.nocache hive/clients/nimbus-el \
            --docker.pull true \
            ${params.DOCKER_BUILDOUTPUT ? '--docker.buildoutput' : ''}
          """
      }
    }
  }

  post {
    cleanup {
      script {
        sh './scripts/hive-cleanup.sh'
      }
    }
    always {
      archiveArtifacts artifacts: 'simulation-results/**', allowEmptyArchive: true
    }
  }
}
