"use strict";
var util = require("util");
const {
    strict
} = require("assert");
const { Resolver } = require("dns");

exports.handler = async (event, context) => {

    console.log("event=", JSON.stringify(event, null, 2));
    console.log("context=", JSON.stringify(context, null, 2));

    String.prototype.toCamelCase = function() {
        return this.replace(/^([A-Z])|\s(\w)/g, function(match, p1, p2, offset) {
            if (p2) return p2.toUpperCase();
            return p1.toLowerCase();        
        });
    };

    function toCamel(o) {
        var newO, origKey, newKey, value
        if (o instanceof Array) {
            return o.map(function (value) {
                if (typeof value === "object") {
                    value = toCamel(value)
                }
                return value
            })
        } else {
            newO = {}
            for (origKey in o) {
                if (o.hasOwnProperty(origKey)) {
                    newKey = (origKey.charAt(0).toLowerCase() + origKey.slice(1) || origKey).toString()
                    value = o[origKey]
                    if (value instanceof Array || (value !== null && value.constructor === Object)) {
                        value = toCamel(value)
                    }
                    newO[newKey] = value
                }
            }
        }
        return newO
    }

    async function sendResponse(event, context, responseStatus, responseData, physicalResourceId, noEcho) {

        return await new Promise((resolve, reject) => {
            var responseBody = JSON.stringify({
                Status: responseStatus,
                Reason: "See the details in CloudWatch Log Stream: " + context.logStreamName,
                PhysicalResourceId: physicalResourceId || context.logStreamName,
                StackId: event.StackId,
                RequestId: event.RequestId,
                LogicalResourceId: event.LogicalResourceId,
                NoEcho: noEcho || false,
                Data: responseData
            });

            console.log("Response body:\n", responseBody);

            var https = require("https");
            var url = require("url");

            var parsedUrl = url.parse(event.ResponseURL);
            var options = {
                hostname: parsedUrl.hostname,
                port: 443,
                path: parsedUrl.path,
                method: "PUT",
                headers: {
                    "content-type": "",
                    "content-length": responseBody.length
                }
            };

            var request = https.request(options, function (response) {
                console.log("Status code: " + response.statusCode);
                console.log("Status message: " + response.statusMessage);
                resolve(JSON.parse(responseBody));
                context.done();
            });

            request.on("error", function (error) {
                console.log("send(..) failed executing https.request(..): " + error);
                reject(error);
                context.done();
            });

            request.write(responseBody);
            request.end();
        });
    }

    async function success(data) {
        return await sendResponse(event, context, "SUCCESS", data, physicalId);
    }

    async function failed(err) {
        return await sendResponse(event, context, "FAILED", err, physicalId);
    }

    async function createCertificate(resourceProperties, serverNamePrefix, newServerNameIdArray) {

        var selfsigned = require('selfsigned');
        const ssgenerate = util.promisify(selfsigned.generate);

        const _shortNames = {
            CN: 'commonName',
            C: 'countryName',
            L: 'localityName',
            ST: 'stateOrProvinceName',
            O: 'organizationName',
            OU: 'organizationalUnitName',
            E: 'emailAddress'
        };
        
        try {
            // Cast integer properties from passed string type back to integer 
            var attributes = toCamel(resourceProperties.Attributes)
            attributes.keySize = parseInt(attributes.keySize) || 1024
            
            // Parse the # of days the certificate should exists, defaulting to 365 if not provided
            attributes.days = parseInt(attributes.days) || 365

            // If an explicit 'ExpiresOn' YYYY-MM-DD is provided, validate that. Must be:
            // 1. Non-empty string
            // 2. In the form YYYY-MM-DD where MM is 01-12, DD is 01-31. Does not check for leap year
            // 3. Must be at least 1 day in the future.
            //
            if (resourceProperties.hasOwnProperty("ExpiresOn")) {
                attributes.days = 365
                if (resourceProperties["ExpiresOn"] !== "") {
                    if (resourceProperties["ExpiresOn"].match(/^\d{4}\-(0[1-9]|1[012])\-(0[1-9]|[12][0-9]|3[01])$/gm) == null) {
                        throw new Error("Invalid 'ExpiresOn' date format. Expected 'YYYY-MM-DD'");
                    }
                    // Calc number of days between new expiration and today (12:00midnight)
                    var curDate = new Date()
                    var expDate = new Date(resourceProperties["ExpiresOn"])
                    attributes.days = Math.round((expDate.setUTCHours(0,0,0)-curDate.setUTCHours(0,0,0)) / (1000*60*60*24))
                }
            }

            if (attributes.days <= 0) {
                throw new Error("'ExpiresOn' or 'Attributes.Days' must result in an expiration date at least one day in the future.");
            }

            // Iterate over provided options list with 'short names' and substitute back 'long names' removing
            // leading/trailing whitespace for the name and value
            var options = []
            for (var o of resourceProperties.Options.split(';')) {
                o = o.split('=')
                o[0] = o[0].trim()
                if (_shortNames[o[0]] != null) {
                    o[0] = _shortNames[o[0]]
                }
                options.push({
                    'name': o[0].toCamelCase(),
                    'value': o[1].trim()
                })
            }
            return await ssgenerate(options, attributes);
        } catch (err) {
            throw new Error("createCertificate() error: " + err.message);
        };
    }


    try {
        var physicalId = event.PhysicalResourceId || "none";
        var stackName = (context.functionName || "").split("-")[0];
        var resourceProperties = event.ResourceProperties;
        var result = {};

        if (event.RequestType == "Create") {

            const createCertificateResponse = await createCertificate(resourceProperties);

            // if (typeof resourceProperties.Attributes.ClientCertificate !== 'undefined' && resourceProperties.Attributes.ClientCertificate == 'true') {
            //     result.ClientCertificatePEM = createCertificateResponse.clientcertificate;
            //     result.ClientPublicPEM = createCertificateResponse.clientpublic;
            //     result.ClientPrivatePEM = createCertificateResponse.clientprivate;
            // }

            if (resourceProperties.UploadTo.toLowerCase() == 'acm') {
                var ACMCLIENT = require('aws-sdk/clients/acm');
                var acmClient = new ACMCLIENT({});

                // Import the certificate into ACM
                const importCertificateResponse = await acmClient.importCertificate({
                    Certificate: createCertificateResponse.cert,
                    PrivateKey: createCertificateResponse.private
                }).promise();

                // Return the CertificateArn and use it as the physicalId for CFT
                result.CertificateArn = physicalId = importCertificateResponse.CertificateArn;
                return await success(result);

            } else if (resourceProperties.UploadTo.toLowerCase() == 'iam') {

                var IAMCLIENT = require('aws-sdk/clients/iam');
                //                const {
                //                    IAMClient,
                //                    UploadServerCertificateCommand
                //                } = require("@aws-sdk/client-iam");

                var iamClient = new IAMCLIENT({});

                physicalId = resourceProperties.ServerCertificateName;
                const uploadServerCertificateResponse = await iamClient.uploadServerCertificate({
                    CertificateBody: createCertificateResponse.cert,
                    PrivateKey: createCertificateResponse.private,
                    ServerCertificateName: physicalId
                }).promise()

                result.CertificateId = uploadServerCertificateResponse.ServerCertificateMetadata.ServerCertificateId;
                result.CertificateArn = uploadServerCertificateResponse.ServerCertificateMetadata.Arn;
                return await success(result);
            } else
                return await success(result);

        } else if (event.RequestType == "Update") {
            var oldResourceProperties = event.OldResourceProperties;

            // Make sure we're not trying to change the upload type
            if (resourceProperties.UploadTo !== oldResourceProperties.UploadTo) {
                return await failed("Can't change 'UpLoad' property for existing certificate");
            } else
                // See if we're making changes
                if (JSON.stringify(oldResourceProperties) === JSON.stringify(resourceProperties)) {
                    // Return the CertificateArn and use it as the physicalId for CFT
                    result.CertificateArn = physicalId;
                    return await success(result);
                } else {
                    // Yes, if the existing certificate was uploaded to IAM, return "can't change" error
                    if (resourceProperties.UploadTo.toLowerCase == 'iam') {
                        return await failed("Can't change certificate imported to IAM");
                    }

                    // Changing existing 'ACM' certificate. Generate a new certificate
                    const createCertificateResponse = await createCertificate(resourceProperties);

                    // And upload to ACM, replacing the existing certificate
                    var ACMCLIENT = require('aws-sdk/clients/acm');
                    var acmClient = new ACMCLIENT({});
                    const importCertificateResponse = await acmClient.importCertificate({
                        CertificateArn: physicalId,
                        Certificate: createCertificateResponse.cert,
                        PrivateKey: createCertificateResponse.private
                    }).promise();

                    // Return the CertificateArn and use it as the physicalId for CFT
                    result.CertificateArn = physicalId = importCertificateResponse.CertificateArn;
                    return await success(result);
                }
        // }
        // if (resourceProperties.UploadTo.toLowerCase() == 'acm') {
        //     var ACMCLIENT = require('aws-sdk/clients/acm');
        //     var acmClient = new ACMCLIENT({});

        //     const getCertificateResponse = await acmClient.getCertificate({
        //         CertificateArn: physicalId
        //     }).promise();

        //     result.Certificate = getCertificateResponse.Certificate;
        //     result.CertificateArn = physicalId;

        //     return await success(result);
        //     //            if (JSON.stringify(resourceProperties) !== JSON.stringify(event.OldResourceProperties)) {
        //     //
        //     //            }

        } else if (event.RequestType == "Delete") {

            if (physicalId == "none") {
                return await success(result);
            }

            var ACMCLIENT = require('aws-sdk/clients/acm');
            var acmClient = new ACMCLIENT({});

            // Poll for period of time to ensure the certificate is not "in use". The certificate can continue to 
            // show as "in use" upwards of 2-3 min after it is nolonger really in use (e.g, the LB Listener was deleted)
            const checkCertificateInUse = async (certificateArn) => {

                const describeCertificateResponse = await acmClient.describeCertificate({
                    CertificateArn: certificateArn
                }).promise();
                if (describeCertificateResponse.Certificate.InUseBy.length > 0) {
                    return describeCertificateResponse.Certificate.InUseBy[0];
                } else
                    return '';
            }

            const asyncInterval = async (callback, delaySeconds, maxSeconds) => {
                var triesLeft = maxSeconds / delaySeconds
                return new Promise((resolve, reject) => {
                  const interval = setInterval(async () => {
                    var inuse_lb = await callback(physicalId)
                    if (!inuse_lb) {
                      resolve();
                      clearInterval(interval);
                    } else if (triesLeft <= 1) {
                      reject(inuse_lb);
                      clearInterval(interval);
                    }
                    triesLeft--;
                  }, delaySeconds*1000);
                });
            }
            
            // Wait up to 5min for the certificate to no longer be 'in-use'
            await (async () => {
                try {
                  await asyncInterval(checkCertificateInUse, 15, 5*60);
                } catch (e) {
                    return await failed({
                        Error: "Unable to delete certificate as still in-use by "+e
                    });
                }

                switch (resourceProperties.UploadTo.toLowerCase()) {
                    case 'acm':

                        const deleteCertificateResponse = await acmClient.deleteCertificate({
                            CertificateArn: physicalId
                        }).promise();
                        return await success(result);

                    case 'iam':
                        var IAMCLIENT = require('aws-sdk/clients/iam');
                        var iamClient = new IAMCLIENT({});
                        const deleteServerCertificateResponse = await iamClient.deleteServerCertificate({
                            ServerCertificateName: physicalId
                        }).promise();
                        return await success(result);
                }
              })();
        } else {
            return await failed({
                Error: "Expected Create, Update or Delete for event.ResourceType"
            });
        }

    } catch (err) {
        return await failed(err);
    }
};
