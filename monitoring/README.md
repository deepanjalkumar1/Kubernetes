
# 1. From your local machine (kubectl must be configured)

            chmod +x deploy-monitoring.sh

            ./deploy-monitoring.sh

            on master node allow security inboud rule for port 32000, 32001, 32002 from source your specific ip address

            sudo tcpdump -n -i any port 32000 2>/dev/null | head -10

            chmod +x deploy-loki.sh

            ./deploy-loki.sh
            
             On Graphana, View FastAPI pod logs:
              
                          1. Left sidebar → Explore (compass icon)
  
                          2. Datasource dropdown → select Loki
  
                          3. Label filters → namespace = default
  
                          4. Add filter  → pod =~ fastapi.*
  
                          5. Click Run query

            Now to have custom view of dashboard do this :

                        chmod +x enable-ingress-metrics.sh

                        sudo bash ./enable-ingress-metrics.sh

                        Step 2 — Import dashboard into Grafana:

                                    Open Grafana → http://<master-public-ip>:32000
                                    
                                    Left sidebar → Dashboards → Import

                                    Click Upload JSON file → select fastapi-dashboard.json

                                    Set Prometheus datasource → your Prometheus

                                    Set Loki datasource → your Loki

                                    Click Import
