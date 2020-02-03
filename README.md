## INTRODUCTION


This is a excerpt of a ruby on rails web app and restful api. It is based on the starter rails application by Logan Sease.

### A GENERAL GUIDELINE FOR CALLING RESTFUL API ENDPOINTS

All the endpoints are implemented through paths that follows this standard REST routing pattern.
By using standard REST, Available endpoints as well as input and responses can be inferred by examining the application data model (schema.rb)

POST / [plural model name] - create a new model, input a json representation of the new model, will return the newly created model

PUT / [plural model name] / id  - update, input a json representation of the model, will return the updated model

GET / [plural model name] / id - get a specific item, will return a json reprentation of the model

GET / [plural model name] - index, or a list of items, possibly filtered by parameters, will return a json array of the model objects

DELETE / plural model name / id - delete an object

Some example Paths:

POST /tokens?username=lsease@gmail.com&password=password

GET /questions?access_token=[token]?format=json

### CODE EXPLANATION:

The code snippets contain controllers for user authentication and sign up using facebook and snapchat and the rest of the user account creating process. It also contains controller code for creating and managing posts and various ways to start a new guess game, generating score and user ranking in the game.

The code samples also include model implementation for user model, user photo model, posts model and all models related to creating a new guess game and recording the response

Along with the project code implementation, we have specs for all the controllers and models included in the code sample. Additionally, the requests folder inside the spec includes the api call testing through rspec
