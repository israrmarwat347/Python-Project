pipeline {
  agent any

  environment {
    DOCKERHUB_USER = 'YOUR_DOCKERHUB_USER'      // <-- replace
    IMAGE_NAME     = "${DOCKERHUB_USER}/notes-app"
    IMAGE_TAG      = "${env.BUILD_NUMBER}"
    AWS_REGION     = 'us-east-1'
    S3_BUCKET      = credentials('s3-artifacts-bucket')  // Jenkins "Secret text"
    KUBE_NAMESPACE = 'notes'
  }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Unit tests') {
      steps {
        sh '''
          python3 -m venv .venv
          . .venv/bin/activate
          pip install --upgrade pip
          pip install -r app/requirements.txt
          PYTHONPATH=. pytest -v --junitxml=test-report.xml app/tests
        '''
      }
      post {
        always { junit allowEmptyResults: true, testResults: 'test-report.xml' }
      }
    }

    stage('Build image') {
      steps {
        sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest .'
      }
    }

    stage('Push image') {
      steps {
        withCredentials([usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'DH_USER',
            passwordVariable: 'DH_PASS')]) {
          sh '''
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
            docker push ${IMAGE_NAME}:${IMAGE_TAG}
            docker push ${IMAGE_NAME}:latest
            docker logout
          '''
        }
      }
    }

    stage('Upload build report to S3') {
      steps {
        withAWS(region: "${AWS_REGION}", credentials: 'aws-creds') {
          sh '''
            echo "Build ${BUILD_NUMBER} image ${IMAGE_NAME}:${IMAGE_TAG}" > build-report.txt
            cat test-report.xml >> build-report.txt || true
            aws s3 cp build-report.txt s3://${S3_BUCKET}/reports/build-${BUILD_NUMBER}.txt
          '''
        }
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
          sh '''
            export KUBECONFIG=$KUBECONFIG_FILE
            kubectl apply -f k8s/namespace.yaml
            kubectl apply -f k8s/configmap.yaml -n ${KUBE_NAMESPACE}
            kubectl apply -f k8s/secret.yaml   -n ${KUBE_NAMESPACE} || echo "secret must exist already"
            kubectl apply -f k8s/postgres.yaml -n ${KUBE_NAMESPACE}
            # inject the new image tag
            sed "s|IMAGE_PLACEHOLDER|${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/app-deployment.yaml \
              | kubectl apply -n ${KUBE_NAMESPACE} -f -
            kubectl apply -f k8s/app-service.yaml -n ${KUBE_NAMESPACE}
            kubectl rollout status deployment/notes-app -n ${KUBE_NAMESPACE} --timeout=180s
          '''
        }
      }
    }

    stage('Smoke test /health') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
          sh '''
            export KUBECONFIG=$KUBECONFIG_FILE
            NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
            NODE_PORT=$(kubectl get svc notes-app -n ${KUBE_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}')
            for i in 1 2 3 4 5 6 7 8 9 10; do
              code=$(curl -s -o /dev/null -w "%{http_code}" http://${NODE_IP}:${NODE_PORT}/health || true)
              if [ "$code" = "200" ]; then echo "healthy"; exit 0; fi
              echo "waiting... ($i) got=$code"; sleep 5
            done
            echo "health check failed"; exit 1
          '''
        }
      }
    }
  }

  post {
    success { echo "Build ${BUILD_NUMBER} deployed OK" }
    failure { echo "Build ${BUILD_NUMBER} FAILED" }
  }
}
