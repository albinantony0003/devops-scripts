try {
    // Path to the master rendering Groovy script on the Jenkins master controller
    def scriptFile = new File("/var/jenkins_home/scripts/deploy_master.groovy") // Update path as per your environment
    
    if (scriptFile.exists()) {
        def master = evaluate(scriptFile)
        return master.render(
            imageName:      "image0name",      // Docker repository image path (e.g. "library/nginx" or "myorg/my-app")
            deployName:     "service-name",    // K8s Deployment resource name
            serviceTitle:   "jenkins-service", // Parameter block title
            namespace:      "namespace",       // K8s Namespace where deployment resides
            credsId:        "dockerhuboat",    // Jenkins credentials ID with Docker Registry access credentials
            kubectlPath:    "/usr/bin/kubectl",// Path to kubectl executable on the Jenkins agent/controller
            kubeconfigPath: "/opt/k8s-creds/EKS" // Path to the EKS Kubeconfig file
        )
    } else {
        return "<b style='color:red;'>⚠️ Deployment script missing on server!</b>"
    }
} catch (Exception e) {
    return "<b style='color:red;'>❌ UI Error:</b> ${e.message}"
}
