# NetworkDiscoveryReport

PowerShell-based network discovery script designed to be run in Azure Automation.

## Output

This script outputs a JSON object with the following schema:
```
{
  "<AzureRegion>": {
    "<Environment>": {
      "VNets": [
        {
          "ID": string,
          "Name": string,
          "AddressPrefixes": [
            {
              "<AddressPrefix>": [
                "SubnetName": string,
                "AddressPrefix": string,
                "RouteTable": {
                  "ID": string,
                  "Name": string,
                  "Classification": string,
                  "Routes": [
                    {
                      "Name": string,
                      "AddressPrefix": string,
                      "NextHopType": string,
                      "NextHopIPAddress": string
                    }
                  ]
                }
                "VMs": {
                  "VMNICCount": int,
                  "PublicIPVMs": [
                    {
                      "VM": {
                        "ID": string,
                        "Name": string
                      }
                      "PIP": {
                        "ID": string,
                        "Name": string,
                        "Allocation": string,
                        "Address": string
                      }
                    }
                  ]
                }
                "LoadBalancers": [
                  "ID": string,
                  "Name": string,
                  "Type": string,
                  "BackendTargets": [
                    {
                      "ID": string,
                      "Name": string,
                      "Type": string
                    }
                  ]
                ]
              ]
            }
          ]
        }
      ],
      "Peerings": [
        {
          "VNetID": string,
          "VNetName": string,
          "RemoteVNetID": string,
          "RemoteVNetName": string,
          "AllowVNetAccess": boolean,
          "AllowForwardedTraffic": boolean,
          "AllowGatewayTransit": boolean,
          "UseRemoteGateways": boolean
        }
      ],
      "LoadBalancers": [
        {
          "ID": string,
          "Name": string,
          "Type": string,
          "BackendTargets": [
            {
              "ID": string,
              "Name": string,
              "Type": string
            }
          ]
        }
      ],
      "VPNs": [
        {
          "ID": string,
          "Name": string,
          "PublicIPs": [
            {
              "ID": string,
              "Name": string,
              "Allocation": string,
              "Address": string
            }
          ],
          "RouteTables": [
            {
              "ID": string,
              "Name": string,
              "Classification": string,
              "Routes": [
                {
                  "Name": string,
                  "AddressPrefix": string,
                  "NextHopType": string,
                  "NextHopIPAddress": string
                }
              ]
            }
          ],
          "VPNClientAddressPool": [
            string
          ]
        }
      ],
      "ExpressRoutes": [
        {
          "ID": string,
          "Name": string,
          "PublicIPs": [
            {
              "ID": string,
              "Name": string,
              "Allocation": string,
              "Address": string
            }
          ],
          "RouteTables": [
            {
              "ID": string,
              "Name": string,
              "Classification": string,
              "Routes": [
                {
                  "Name": string,
                  "AddressPrefix": string,
                  "NextHopType": string,
                  "NextHopIPAddress": string
                }
              ]
            }
          ]
        }
      ]
    }
  }
}
```

This schema was designed around the following format request:
> - For each region: [...]
>   - For each environment (production & non-production):
>     - List each VNET (VNET_ID + name)
>       - List the CIDR blocks in the VNET
>         - List the subnets per CIDR block (plus subnet name, if any)
>           - List the routing table for that subnet, indicating public or private access - a cut-n-paste or screenshot would be great
>           - How many VMs are in the subnet? (a count is more than enough)
>             - Are any [public] IPs on any VMs?  If so, please list the VM and IP.
>       - List any load balancers in the VNET and what they are sitting in front of (target list of VMs?)
>       - Is there an internet gateway (direct internet access which may not be passing through our Palo Alto tiers)?
>     - List each VNET peering relationship (if any)
>     - List VPNs terminating at the cloud-native AWS level.
>     - List Express Routes and termination points/routing tables

## Prerequisites

If running from an Azure Automation Account, the AAA must have a Run-As account connected to your tenant. Additionally, this Run-As account must be given at least Reader permissions over all subscriptions to evaluate.

Additionally, the following modules are required:
- AzureRM.Network
- AzureRM.Profile

## Configuration

In order to identify the environment type of each subscription (Production or Non-Production), please list the subscription IDs in the array declarations for Production and Non-Production IDs on lines 1 and 2, respectively.

If this is to be run on a local workstation rather than through Azure Automation, comment out the connection commands on lines 74 and 75. You will need to manually log in using Connect-AzureRMAccount and set $connection.TenantID to your desired tenant before running the script.

## To-do

- Computational optimizations/garbage collection
- Environment detection for non-AAA use cases
- Warning suppression for AzureRM deprecation
  - Create an Az variant if there is demand; since AAAs default to AzureRM at this time I continue to use AzureRM commandlets to reduce module prerequisites
- Options to forward JSON output to a storage account, webhook, or other external location
- Options for reduced output, e.g. pruning empty arrays and null values
- Code documentation
