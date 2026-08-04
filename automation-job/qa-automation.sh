#!/bin/bash
cd $workdir
echo "=================="
. ~/.bashrc
echo "Installing requirements"
/var/lib/jenkins/qa-automation-env/bin/pip install -r requirements.txt > /dev/null
source /var/lib/jenkins/qa-automation-env/bin/activate
echo "Starting the test"
pytest --profile canary -n 40 -v -s --html=pytest_report.html --junitxml=pytest_results.xml || echo "Tests completed with failures" 
BUILD_TIMESTAMP_QA=$(date +"%Y%m%d_%H%M")
cd /var/lib/jenkins/workspace/ && \
zip -r /var/lib/jenkins/qa_automation_results/Production-QA-Automation-Script-JobNum${BUILD_NUMBER}-${BUILD_TIMESTAMP_QA}.zip Production-QA-Automation-Script