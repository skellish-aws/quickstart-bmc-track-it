"use strict";
var util = require("util");
const {
    strict
} = require("assert");

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

            if (resourceProperties.hasOwnProperty("ExpiresOn")) {
                if (resourceProperties["ExpiresOn"].match(/^\d{4}\-\d{1,2}\-\d{1,2}$/) == null) {
                    throw new Error("Invalid 'ExpiresOn' date format. Expected 'YYYY-MM-DD'");
                }
                // Calc number of days between new expiration and today (12:00midnight)
                var curDate = new Date()
                var expDate = new Date(resourceProperties["ExpiresOn"])
                attributes.days = Math.round((expDate.setUTCHours(0,0,0)-curDate.setUTCHours(0,0,0)) / (1000*60*60*24))

                if (attributes.days <= 0) {
                    throw new Error("'ExpiresOn' date must be at least one day in the future.");
                }
            } else 
                attributes.days = parseInt(attributes.days) || 365

            var options = []
            for (var o of resourceProperties.Options.split(';')) {
                o = o.split('=')
                if (_shortNames[o[0]] != null) {
                    o[0] = _shortNames[o[0]]
                }
                options.push({
                    'name': o[0].toCamelCase(),
                    'value': o[1]
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

                // {
                //     Path: '/', 
                //     ServerCertificateName: 'TestCert', 
                //     ServerCertificateId: 'ASCARMBBIT4EHITCJ36IC', 
                //     Arn: 'arn:aws:iam::094559051528:server-certificate/TestCert', 
                //     UploadDate: Sun Mar 07 2021 01:20:47 GMT-0500 (Eastern Standard Time)
                // }

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
        }
        if (resourceProperties.UploadTo.toLowerCase() == 'acm') {
            var ACMCLIENT = require('aws-sdk/clients/acm');
            var acmClient = new ACMCLIENT({});

            const getCertificateResponse = await acmClient.getCertificate({
                CertificateArn: physicalId
            }).promise();

            result.Certificate = getCertificateResponse.Certificate;
            result.CertificateArn = physicalId;

            return await success(result);
            //            if (JSON.stringify(resourceProperties) !== JSON.stringify(event.OldResourceProperties)) {
            //
            //            }

        } else if (event.RequestType == "Delete") {

            if (physicalId == "none") {
                return await success(result);
            }

            switch (resourceProperties.UploadTo.toLowerCase()) {
                case 'acm':
                    var ACMCLIENT = require('aws-sdk/clients/acm');
                    var acmClient = new ACMCLIENT({});
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
        } else {
            return await failed({
                Error: "Expected Create, Update or Delete for event.ResourceType"
            });
        }

    } catch (err) {
        return await failed(err);
    }
};

// const createEvent = {
//     "RequestType": "Create",
//     "ServiceToken": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-FSIY0U5V08RK",
//     "ResponseURL": "https://cloudformation-custom-resource-response-useast1.s3.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-east-1%3A094559051528%3Astack/ss2/38ac72e0-8212-11eb-8fb3-0e794c84352f%7CSelfSignedCert%7C270a2c1e-36e4-43c3-a136-7b4e929c7054?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20210311T023358Z&X-Amz-SignedHeaders=host&X-Amz-Expires=7199&X-Amz-Credential=AKIA6L7Q4OWT3UXBW442%2F20210311%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Signature=5d6e4dcbd5ff6c2002a9192503beaaed851575530439d2713e5ff92c8e443326",
//     "StackId": "arn:aws:cloudformation:us-east-1:094559051528:stack/ss2/38ac72e0-8212-11eb-8fb3-0e794c84352f",
//     "RequestId": "270a2c1e-36e4-43c3-a136-7b4e929c7054",
//     "LogicalResourceId": "SelfSignedCert",
//     "ResourceType": "Custom::SelfSignedCert",
//     "ResourceProperties": {
//         "ServiceToken": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-FSIY0U5V08RK",
// //        "Options": "CommonName=example.org;CountryName=US;LocalityName=New Jersey;StateOrProvinceName=NJ;OrganizationName=example;OrganizationalUnitName=dev;EmailAddress=skellish@amazon.com",
//         "Options": "CN=example.org;C=US;L=New Jersey;ST=NJ;O=example;OU=dev;E=skellish@amazon.com",
//         "ExpiresOn": "2021-04-1",
//         "Attributes": {
// //             "Days": "10",
//             "KeySize": "2048"
//         },
//         "ServerCertificateName": "ss2-TestCert",
//         "UploadTo": "acm"
//     }
// }

// var updateevent= 
// {
//     "RequestType": "Update",
//     "ServiceToken": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-1TSU1Z6LB1KE4",
//     "ResponseURL": "https://cloudformation-custom-resource-response-useast1.s3.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-east-1%3A094559051528%3Astack/ss1/21888470-8233-11eb-bf70-0ecd7efaa235%7CSelfSignedCert%7C49a03a6e-a55c-44a2-acec-c8dd4d67d40c?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20210311T063108Z&X-Amz-SignedHeaders=host&X-Amz-Expires=7200&X-Amz-Credential=AKIA6L7Q4OWT3UXBW442%2F20210311%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Signature=643f3bbca95990ae6213c88b8c0cc61adcfab572274e12413c06ad722efdf6bc",
//     "StackId": "arn:aws:cloudformation:us-east-1:094559051528:stack/ss1/21888470-8233-11eb-bf70-0ecd7efaa235",
//     "RequestId": "49a03a6e-a55c-44a2-acec-c8dd4d67d40c",
//     "LogicalResourceId": "SelfSignedCert",
//     "PhysicalResourceId": "arn:aws:acm:us-east-1:094559051528:certificate/88f9d08b-92ee-49f7-9574-27d1300e0bb7",
//     "ResourceType": "Custom::SelfSignedCert",
//     "ResourceProperties": {
//         "ServiceToken": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-1TSU1Z6LB1KE4",
//         "Options": {
//             "OrganizationName": "example",
//             "CountryName": "US",
//             "LocalityName": "New York",
//             "StateOrProvinceName": "NJ",
//             "OrganizationalUnitName": "dev",
//             "EmailAddress": "skellish@amazon.com",
//             "CommonName": "example.org"
//         },
//         "Attributes": {
//             "Days": "10",
//             "KeySize": "2048"
//         },
//         "ServerCertificateName": "ss1-TestCert",
//         "UploadTo": "acm"
//     },
//     "OldResourceProperties": {
//         "ServiceToken": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-1TSU1Z6LB1KE4",
//         "Options": {
//             "OrganizationName": "example",
//             "CountryName": "US",
//             "LocalityName": "New York",
//             "StateOrProvinceName": "NY",
//             "OrganizationalUnitName": "dev",
//             "EmailAddress": "skellish@amazon.com",
//             "CommonName": "example.org"
//         },
//         "Attributes": {
//             "Days": "10",
//             "KeySize": "2048"
//         },
//         "ServerCertificateName": "ss1-TestCert",
//         "UploadTo": "acm"
//     }
// }

// const context = {
//     "callbackWaitsForEmptyEventLoop": true,
//     "functionVersion": "$LATEST",
//     "functionName": "ss1-SelfSignedCertLambdaFunction-FSIY0U5V08RK",
//     "memoryLimitInMB": "128",
//     "logGroupName": "/aws/lambda/ss1-SelfSignedCertLambdaFunction-FSIY0U5V08RK",
//     "logStreamName": "2021/03/11/[$LATEST]cd6fe0797b674038be198ea2b4c48eaa",
//     "invokedFunctionArn": "arn:aws:lambda:us-east-1:094559051528:function:ss1-SelfSignedCertLambdaFunction-FSIY0U5V08RK",
//     "awsRequestId": "ccc95cc2-3d61-448b-a8db-eede8c830dfc"
// }

// try {
//     var r = this.handler(createEvent, context);
//     console.log(r);
// } catch (err) {
//     console.log(err);
// }